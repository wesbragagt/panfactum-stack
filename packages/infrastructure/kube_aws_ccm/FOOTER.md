Installs the AWS CCM node controller only. Service/load-balancer, route and node-lifecycle controllers are intentionally disabled. The role grants EC2 discovery only. No namespace, instance, worker, load balancer or route is created.

Requires Kubernetes 1.37, pre-existing workload identity and a node with a valid AWS providerID. Supply existing VPC/subnet/zone to avoid IMDS dependency. The Helm image is explicitly pinned independently of chart defaults. Existing short node names can be retained by setting kubelet provider-id before enabling external cloud-provider mode. Install CCM before enabling external mode; its tolerations allow initialization taints. Do not rename the existing node.

For self-managed clusters pass both OIDC inputs. Source-IP restrictions default on; explicit opt-out is required for changing public egress. Issuer, subject and audience trust conditions always apply. EKS defaults in shared modules are unchanged.

The chart ClusterRole is narrowed to node metadata, events, Lease election and delegated secure-serving checks; node deletion, Service/PV mutation and wildcard verbs are excluded. The chart's controller-credentials Role remains chart-owned, with per-controller credentials disabled. Offline chart contract checks live in `tests/check_render.py`; pass a manifest rendered from the actual planned values plus a placeholder IRSA role annotation.
