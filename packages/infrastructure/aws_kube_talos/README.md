# Talos on AWS

Terragrunt consumers supply cluster choices and decrypt their SOPS bundle. The module owns Talos configuration documents, EC2 launch templates, Spot and on-demand worker configuration, and OIDC discovery.

```hcl
terraform {
  source = "${get_repo_root()}/forks/panfactum/packages/infrastructure//aws_kube_talos"
}

dependency "vpc" {
  config_path = "../vpc"
}

inputs = {
  cluster_name = "my-cluster"
  vpc_id       = dependency.vpc.outputs.vpc_id
  secrets_bundle = yamldecode(sops_decrypt_file("${get_terragrunt_dir()}/talos-secrets.yaml"))
  control_plane_private_ips = ["10.0.64.20"]
  private_api_dns_name = "api.my-cluster.internal"
  operator_tunnel_security_group_id = "sg-0123456789abcdef0" # fck-nat SSM tunnel hosts
}
```

Talos-managed Flannel, kube-proxy and CoreDNS are disabled by default so Panfactum modules can manage networking and DNS. `cilium_enabled = true` disables Flannel and kube-proxy; it does not install Cilium. Set `cilium_enabled = false` and `core_dns_enabled = true` only when using Talos-managed networking and DNS.

For custom factory images, pass `ami_id` and the matching `installer_image`. Enable `aws_node_config_enabled` for primary-interface DHCP, ECR credential-provider configuration, external CCM settings and worker lifecycle labels. Supply `pod_subnets` and `service_subnets` when the defaults overlap another cluster. `worker_instance_profile_arn` grants workers their AWS identity.

The module creates `<cluster_name>-oidc-<aws_account_id>`, publishes discovery and public JWKS derived from the existing service-account signing key, and configures the API server issuer and JWKS URL. Consumers supply no OIDC inputs. Planning requires Python 3 and OpenSSL. Signing-key rotation requires a separate overlap procedure retaining old verification keys until their tokens expire.

The Talos API and Kubernetes API certificates include the SAN `127.0.0.1`, so clients can verify TLS through an SSM port forward. `operator_tunnel_security_group_id` opens 6443 and 50000 to the tunnel hosts. The default `talos_api_endpoint = "127.0.0.1"` runs Talos provider operations through a tunnel forwarding 127.0.0.1:50000 to the controller; plans and applies fail unless the tunnel is up. `talos_api_allowed_cidrs` and `kube_api_allowed_cidrs` default to `[]`; set them only for direct access from fixed IPs. Controllers default to PRIVATE_A/B/C subnets without public addresses or an Elastic IP. Supply `private_api_dns_name` or `control_plane_private_ips` for the cluster endpoint. Existing public-controller callers must set `control_plane_public_ip_enabled = true` and select PUBLIC subnets; set `talos_api_endpoint = null` only for direct Talos access through the Elastic IP.

To bootstrap a new cluster with both CIDR lists empty, set `operator_tunnel_security_group_id` to an SSM-registered host in the VPC and point `talos_api_endpoint` at the local end of a forward to the controller's `<ip>:50000`. Open that forward once the apply launches the controller (step 5), or fix the address with `control_plane_private_ips` and open it before `terragrunt apply`. The control plane user data carries the `127.0.0.1` SANs, so the first Talos call validates without `--insecure`.

Existing callers can continue supplying provider-shaped `machine_secrets` and `client_configuration`. New callers should pass `secrets_bundle`. Keep the bundle outside the cluster for recovery. Sensitive credentials still enter Terraform state and EC2 user data.

## Bootstrap a new cluster

This guide covers a minimal private cluster: private controllers, Cilium installed separately and `aws_node_config_enabled = false`. The AWS-integrated path (ENI IPAM, external CCM) is listed at the end.

1. Prepare the network. Reuse an existing VPC and subnets, or create them with a separate network module first. Pass the VPC ID and select subnets by Name tag. Check subnet capacity, routes and outbound access. Workers default to `PRIVATE_A/B/C` without public IPs, so confirm those subnets route outbound through NAT. Workers in PUBLIC subnets without NAT need `worker_public_ip_enabled = true`.
2. Prepare the caller. Use the example above, plus a `dependency "vpc"` block that supplies `vpc_id`. Choose a unique cluster name and capacity. `control_plane_private_ips` is optional for bootstrap, because step 5 finds the controller's address after launch. `operator_tunnel_security_group_id` must belong to an SSM-registered host that can reach the controllers; note its managed instance ID and confirm you have `ssm:StartSession` on it. If you set `private_api_dns_name`, its parent zone becomes a private hosted zone attached to the VPC. Clusters sharing a VPC need a different parent zone each (for example `api.a.internal` and `api.b.internal`), otherwise two modules create a zone with the same name.
3. Create the secrets bundle. Add a SOPS creation rule for the target path, then run `python3 scripts/gen_talos_secrets.py <path-to-talos-secrets.yaml>` from this module directory with `talosctl` and `sops` available. Keep an encrypted copy outside the cluster. Do not reuse another cluster's bundle.
4. Check the OIDC prerequisites. The module always publishes public OIDC discovery in an S3 bucket with a public policy, so account-level S3 Block Public Access must allow it, and the applying principal needs permission to create an IAM OIDC provider. After the apply, confirm that `<issuer>/.well-known/openid-configuration` and `<issuer>/keys.json` are readable without credentials.
5. Register the cluster's local ports in `.kube/talos-clusters.json` before the first apply and set `talos_api_endpoint = "127.0.0.1:<talos_port>"` in the caller. The controller does not exist yet, so its private IP is unknown until the apply launches it. In this repository, start the apply (step 6) and run `scripts/cluster-access.py --bootstrap --cluster NAME` alongside it. The command waits up to `--wait` seconds (default 900) for `<cluster>-control-plane-0` in state `pending` or `running`, then forwards only the Talos port to it through an Online `nat-*` host and prints the endpoint line. Pass `--talos-port` to use another local port. After the first apply, `scripts/cluster-access.py --ensure --cluster NAME` opens both forwards (default `6443` and `50000`) to the controller's private IP. Keep them running for every provider operation. All provider calls use one endpoint, so with three controllers you must repoint the forward at a healthy controller if the first one is down.
6. Plan and apply according to your approval rules. The module starts the controllers, applies Talos configuration, bootstraps etcd, retrieves kubeconfig and starts the workers. The Talos provider v0.12.0 retries initial connection errors other than `InvalidArgument` for 10 minutes by default. Verified on 2026-11-18: an SSM forward opened to a controller's private IP while the instance was still `pending` started working once Talos listened (first certificate 24 seconds after launch, then 30 of 30 handshakes without restarting the forward), so the apply can run while `--bootstrap` holds the forward. If the apply cannot connect, target everything the first call needs, not only the instance: `aws_instance.control_plane`, `aws_security_group.nodes`, `aws_vpc_security_group_ingress_rule.operator_tunnel`, `aws_vpc_security_group_ingress_rule.self`, `aws_vpc_security_group_egress_rule.nodes_all` and `aws_route53_record.private_api` if used. Then confirm `talosctl --talosconfig <file> version` succeeds with authentication, and run a fresh full plan and apply.
7. Never run a full apply to recover an existing cluster without checking the bootstrap resource. If `talos_machine_bootstrap.this` is missing from state and the replacement controller has no etcd data, the apply initializes empty etcd. Exclude it, restore the snapshot manually, then reconcile (see `evidence/talos-private-controller/controller-migration-review.md` for a verified drill).
8. Write a kubeconfig for the tunnel. The `kubeconfig` output uses the in-VPC endpoint. Save a private copy, set its `server` to `https://127.0.0.1:6443`, keep the CA data and use it for `kubectl` and downstream Kubernetes and Helm providers. `scripts/cluster-access.py` in this repository does this for the homelab clusters.
9. Install Cilium and CoreDNS separately; enabling Cilium here does not install them. Install other services in dependency order. Verify node readiness, pod networking, DNS and outbound access, then run a fresh plan to check convergence.
10. Verify etcd backups. The CronJob runs Sidero's [talos-backup](https://github.com/siderolabs/talos-backup) with its age encryption disabled; S3 encrypts each snapshot with the backup KMS key by bucket default. It reaches Talos through the `talos.default` Service, so backups continue while any controller is up. Talos installs the `etcd-backup` namespace, AWS credentials Secret and Talos ServiceAccount as inline manifests, so the `etcd_backup_cronjob_manifest` output alone cannot recreate them. Check that `kubectl -n etcd-backup get cronjob,secret,serviceaccounts.talos.dev` lists all three, run `kubectl -n etcd-backup create job --from=cronjob/etcd-backup test-1`, and confirm a new `<cluster>-<timestamp>.snap` object under `etcd/<cluster>/` in the `etcd_backup_bucket` output. Talos does not update inline manifests that already exist, so on an existing cluster apply CronJob changes from the `etcd_backup_cronjob_manifest` output and rotate the IAM key by updating the Secret.

### AWS-integrated path

`pod_subnets` and `service_subnets` reach the machine configuration only when `aws_node_config_enabled = true`; otherwise they are ignored. That flag also sets kubelet `cloud-provider=external`, so you must install the AWS cloud controller manager and give workers an identity through `worker_instance_profile_arn`. Do this when you need Cilium ENI IPAM. For the minimal path, keep the Talos default pod and service ranges and make sure they do not overlap other networks you route to.
