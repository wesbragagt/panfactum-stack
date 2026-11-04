## Usage

### Talos (opt-in)

`cluster_type = "talos"` avoids EKS API lookups and ENI/IRSA resources. It defaults to
cluster-pool IPAM, IPv4 masquerading with tunnel routing, KubePrism
`localhost:7445`, Talos-compatible capabilities/cgroups, one operator and a
control-plane toleration. Set `ipam_mode = "kubernetes"` only if that matches the
cluster's existing PodCIDR allocation. The EKS defaults remain ENI/native routing,
EKS endpoint discovery, IRSA and two operators; moved blocks preserve existing
namespace/IRSA state addresses when these become conditional.

For an **existing** Talos installation, preserve the chart version, namespace and
IPAM mode. Example inputs for the homelab prototype (not a new install):

```hcl
cluster_type               = "talos"
cilium_helm_version        = "1.20.4"
namespace                  = "kube-system"
namespace_create           = false
ipam_mode                  = "cluster-pool"
cluster_pool_ipv4_cidrs     = ["10.244.0.0/16"]
sla_target                 = 1
pull_through_cache_enabled = false
vpa_enabled                = false
monitoring_enabled         = false
```

Import the existing release to `helm_release.cilium` with ID
`kube-system/cilium` before adoption; use a reviewed declarative import plan,
not a second Helm install. `namespace_create=false` avoids taking ownership of
`kube-system` and creating Panfactum namespace RBAC there. Never import that
namespace into this module. `values_overrides` accepts extra YAML documents,
merged after module defaults, for deliberate adoption adjustments.

The module adds Panfactum pod labels, resource requests, tolerations, an operator
PDB and other common Cilium defaults. It sets `cni.exclusive=false`; an existing
release may use a different value. Import alone does not make these values a
no-op: review the complete Helm diff and scheduling/resource budget before
applying. Bootstrap without ECR pull-through until the cache/policies exist.
Enable VPA/monitoring only after their CRDs exist. Helm provider 3 requires a
`kubernetes = { ... }` provider attribute; older Panfactum caller templates using
a `kubernetes { ... }` block need a caller-level override before planning. This compatibility work is not
proof of an unchanged EKS caller plan or completed live Talos adoption.

Local checks:

```sh
tofu init -backend=false
tofu validate
python3 tests/test_platform.py
# Optional chart rendering check (requires Helm, PyYAML, chart repository access):
python3 tests/render.py
```

The platform tests evaluate actual module expressions with no providers, cluster
access or state writes. They cover default EKS network values/resource gates,
Talos cluster-pool and Kubernetes IPAM, existing namespace reuse and disabling
ENI IAM resources even for an invalid Talos/ENI combination (the Helm precondition
rejects that combination).
