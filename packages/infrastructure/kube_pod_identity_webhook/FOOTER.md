Deploys the upstream [Amazon EKS pod identity webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) (`v0.6.17`, pinned by digest) on self-managed clusters such as Talos. For every new pod whose ServiceAccount carries `eks.amazonaws.com/role-arn` (the annotation written by `kube_sa_auth_aws`), it injects a projected token with audience `sts.amazonaws.com` at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token` plus `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_REGION`, `AWS_DEFAULT_REGION` and `AWS_STS_REGIONAL_ENDPOINTS=regional`.

Do not install this module on EKS. EKS already runs this webhook, and two webhooks must never both mutate pods.

## Resource names

All objects use `var.name` (default `pod-identity-webhook`) in `var.namespace` (default `kube-system`): Deployment, Service, PodDisruptionBudget, ServiceAccount, ClusterRole, ClusterRoleBinding and MutatingWebhookConfiguration. Certificates and Secrets are `<name>-ca` and `<name>-tls`. Issuers are `<name>-selfsigned` and `<name>-ca`. The default name does not collide with a Helm release named `amazon-eks-pod-identity-webhook`.

## Namespace

The default is `kube-system` with `create_namespace = false`. `kube-system` exists before any add-on, so the webhook has no ordering dependency on `kube_namespace`. Kyverno's pod mutation also excludes `kube-system`. Set `create_namespace = true` to create another namespace through `kube_namespace` with `linkerd_inject = false`. The priority class is `cluster-important`, so the `system-cluster-critical` namespace restriction does not apply.

## High availability

- Two replicas at every SLA level. With `failurePolicy: Fail`, one replica is a single point of failure for pod creation. The cluster has three Spot controllers, one per zone, so a third replica would stay Pending whenever one controller is down.
- Controller nodes only (`panfactum.com/class=controller`), with a toleration for `node-role.kubernetes.io/control-plane`.
- Required hostname anti-affinity and a preferred (`ScheduleAnyway`) zone spread.
- Rolling update with `maxSurge: 0` and `maxUnavailable: 1`. Required anti-affinity with two free controllers leaves no node for a surge pod.
- PodDisruptionBudget with `maxUnavailable: 1` and `unhealthyPodEvictionPolicy: AlwaysAllow`, so a broken pod never blocks a node drain.
- `preStop` sleeps 5 seconds so the pod keeps serving while its endpoint is removed. `terminationGracePeriodSeconds` is 30.
- HTTPS probes on `/healthz` with a 3 second timeout. Liveness fails after 6 misses because the 1 second default timed out at start.
- Requests: 10m CPU, 49Mi memory. Limit: 64Mi memory. Observed peak was 37 MB and 2m CPU.
- No VPA, no Linkerd sidecar and no pull-through cache. These are installed after this webhook. That is why the module does not use `kube_deployment`.
- `/healthz` always returns ok, and a replica serves before its ServiceAccount cache syncs. With the upstream default grace period of 0, a cache miss admits the pod without credentials. `service_account_lookup_grace_period` (default `2s`) makes a replica fetch the ServiceAccount from the API and wait up to that long.
- Replicas are independent; there is no leader election.

The Deployment is a `kubectl_manifest` because the pinned `hashicorp/kubernetes` 2.35.0 provider has no `preStop.sleep` handler and the image has no shell for an exec sleep.

## Bootstrap exemption

The webhook uses `failurePolicy: Fail`, so a pod with an IRSA role never starts without credentials. To keep the cluster recoverable when no replica answers, the `objectSelector` ANDs these expressions:

- `eks.amazonaws.com/skip-pod-identity-webhook DoesNotExist`: the upstream opt-out label.
- `app.kubernetes.io/name NotIn [amazon-eks-pod-identity-webhook]`: the webhook's own pods, so it can always restart itself.
- `bootstrap_exempt_selector_expressions`, default `k8s-app NotIn [cilium, cilium-envoy, kube-dns]` and `io.cilium/app NotIn [operator]`: networking and DNS, which every webhook call depends on.

None of the exempt ServiceAccounts has an IRSA annotation. `aws-cloud-controller-manager` is not exempt because it uses IRSA, and an exempt pod would start without credentials. The webhook needs only Cilium and the API server, so it does not depend on the CCM. Never add a pod with an IRSA role to the exemption list.

`timeoutSeconds` is 10. A 5 second timeout would stall pod creation for less time when a replica is unreachable, but a replica waiting the 2 second grace period on a slow API server could then fail valid requests.

## Certificates

The chain uses cert-manager with namespaced Issuers. The cluster's Vault-backed ClusterIssuers would create a cycle, because Vault needs IRSA for KMS auto-unseal.

1. Self-signed Issuer `<name>-selfsigned`.
2. CA Certificate `<name>-ca`: `isCA`, ECDSA P-256, 87600h, renewed 720h early, private key kept on renewal.
3. CA Issuer `<name>-ca`.
4. Serving Certificate `<name>-tls`: ECDSA P-256, 2160h, renewed 720h early, new private key on each renewal, DNS names for `<name>.<namespace>.svc` and `<name>.<namespace>.svc.cluster.local`.

The webhook configuration has `cert-manager.io/inject-ca-from: <namespace>/<name>-tls`. cainjector copies the serving Secret's `ca.crt`, which is the CA certificate, so serving-certificate renewals never change the bundle. The webhook reloads renewed files without a restart. Terraform waits until the bundle is injected. The CA keeps its key on renewal, so leaves signed before a CA renewal still verify.

## Migrating from a manual Helm release

Two webhooks must never both mutate pods. With both registered and both failing closed, pod creation needs both to answer, and the two configurations can disagree.

1. Apply with `mutating_webhook_enabled = false`. This creates everything except the webhook configuration. Check that both replicas are Ready on different controllers and both Certificates are Ready.
2. Canary the new replicas without registering them. Port-forward to the Deployment's port 8443, then POST a `admission.k8s.io/v1beta1` AdmissionReview with `dryRun: true` for a pod using an IRSA ServiceAccount to `https://127.0.0.1:<port>/mutate` with `Content-Type: application/json`. The base64 `response.patch` must contain `AWS_ROLE_ARN`.
3. Switch: delete the Helm release's MutatingWebhookConfiguration, then apply with `mutating_webhook_enabled = true` right away. Confirm with `kubectl run --dry-run=server -o yaml` using an IRSA ServiceAccount; the output must contain `AWS_ROLE_ARN`.
4. Audit: restart every pod with an IRSA ServiceAccount but no `AWS_ROLE_ARN` env var. Only pods created between the delete and the apply in step 3 can be affected.
5. Uninstall the Helm release.

## Deviations from the original task spec

- Two replicas at every SLA level instead of one at level 1, because `failurePolicy` is `Fail`. There is no SLA branch, so the module does not read `pf_metadata`.
- `failurePolicy: Fail` with the label exemption above, instead of `Ignore`. With `Ignore`, a pod created during an outage starts without credentials and fails later.
- A namespaced cert-manager CA through `kube_internal_cert` (`use_cluster_issuer = false`), instead of the `tls` provider. Certificates renew in the cluster instead of only on apply, and no private key is stored in Terraform state.
- The namespace defaults to `kube-system`, not `pod-identity-webhook`.
- `reinvocationPolicy: Never`, as in the upstream chart, instead of `IfNeeded`. `admissionReviewVersions` is `v1beta1` only, because v0.6.17 answers only v1beta1.
- The Deployment is a `kubectl_manifest`, not `kubernetes_deployment_v1` (see above).
- Inputs added: `name`, `create_namespace`, `region`, `service_account_lookup_grace_period`, `mutating_webhook_enabled`, `bootstrap_exempt_selector_expressions`. `log_verbosity` is dropped.
