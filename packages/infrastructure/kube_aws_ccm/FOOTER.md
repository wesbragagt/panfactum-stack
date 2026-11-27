Installs the AWS CCM node controller on a Talos cluster built by `aws_kube_talos`. Service/load-balancer and route controllers are disabled, and the role grants EC2 discovery only. No namespace, instance, worker, load balancer or route is created.

Apply order: `aws_kube_talos`, `kube_cilium`, `kube_aws_ccm`, then `kube_core_dns`. Pass the `cluster` and `controller_provider_ids` outputs of `aws_kube_talos` as the only required inputs. The module derives the region from the AWS provider and the VPC, subnet and zone for `cloud.conf` from the controller with the lowest private IP. CCM runs on the host network and reaches the API through KubePrism (`127.0.0.1:7445`), with a projected web identity token for its IAM role.

Before CCM installs, `scripts/controller_provider_id.py` sets `spec.providerID` on each controller Node that has none. It leaves a matching ID alone and fails on a different one. It reaches the cluster with the same kubeconfig (`KUBE_CONFIG_PATH`), context (`PF_KUBE_CONFIG_CONTEXT`) and server (`PF_KUBE_API_SERVER`) as the generated Kubernetes provider. `environments/panfactum.hcl` exports the last two on `apply`.

Set `image_version` to the CCM release for the cluster's Kubernetes minor. It defaults to `v1.36.1`. During a minor upgrade the image may be at most one minor behind the API server.

The chart ClusterRole is narrowed to node metadata, events, Lease election and delegated secure-serving checks; Service and PV mutation and wildcard verbs are excluded. The chart's controller-credentials Role remains chart-owned, with per-controller credentials disabled. Offline chart contract checks live in `tests/check_render.py`; pass a manifest rendered from the actual planned values plus a placeholder IRSA role annotation.
