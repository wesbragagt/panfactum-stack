# Talos worker path

`cluster_type=eks` preserves the original Bottlerocket resources. `moved.tf` moves
all original resource/module/data addresses to their indexed equivalents so
adding the Talos branch does not recreate an existing EKS deployment. Switching
an existing EKS caller to Talos is a migration that can destroy its old pools;
inspect the full plan and obtain approval. Homelab uses a new caller/state.

The opt-in Talos path reuses the EKS arm64 NodePools (spot-arm, burstable-arm,
on-demand-arm and their wf- variants) with the same names, taints, labels, weights,
requirements and disruption. Their node classes (default, spot, burstable) are
Custom EC2NodeClasses on the pinned arm64 Talos AMI, with an encrypted gp3 root
and IMDSv2/hop1. The amd64-only pools stay EKS-only because aws_kube_talos
outputs no amd64 Talos AMI. Per-class kubelet settings follow kube_node_settings:
shutdownGracePeriod 60m for default, 2m for spot and burstable.

Optional `talos_kubelet_reservations` (default null, output unchanged) renders explicit
reservations, hard eviction, image GC and maxPods into both the worker KubeletConfig
and NodeClass spec.kubelet. Only spec.kubelet gets `node_class_system_ephemeral_storage`,
which models filesystem loss for one root volume size; a precondition rejects other sizes.

Talos must register with the temporary karpenter.sh/unregistered:NoExecute taint
in KubeletConfig.config.registerWithTaints, use FQDN registration for AWS CCM
instance discovery, and enable external cloud provider mode. Do not put this
registration taint in persistent KubeNodeConfig.taints (Talos would re-add it).
The worker config's KubeNodeConfig labels and taints are removed so Karpenter
applies each pool's own. Startup taints match EKS: the Cilium agent and the
kube_linkerd remove-taint sidecar on linkerd-cni clear them.
Set `linkerd_startup_taint_enabled = false` on clusters without Linkerd CNI.

With `ebs_csi_startup_taint_enabled = true`, each NodePool also has
`ebs.csi.aws.com/agent-not-ready:NoExecute`. The EBS CSI node driver removes it
after initialization. Enable it only when that driver is installed and can
patch Nodes. Karpenter startup taints apply to new NodeClaims, so existing
Nodes are not retroactively gated.

For Talos, supply `talos_launch`, `node_instance_profile`, and
`talos_worker_bootstrap`. The launch object selects Talos and contains the AMI,
VPC, security group, and subnet names. Read the worker cluster settings and
version-matched installer from the Talos `node_bootstrap` output. Pass the public OS and Kubernetes CA
certificates, discovery identity, bootstrap token, and trust token. Pass only
those fields in Terragrunt. Use `talos_worker_config` for an explicit worker YAML
override. AWS user data, OpenTofu state, and the EC2NodeClass contain join
credentials. Restrict access to all three. The `user_data` output is sensitive.

Validation: `env -i HOME=$HOME PATH=$PATH tofu test`. tests/eks_unchanged.tftest.hcl
pins the EKS manifests by hash; tests/talos_node_pools.tftest.hcl checks the Talos
pool set. Live acceptance requires a Ready NodeClaim/Node per pool with matching
AWS providerID, startup taint removal and Cilium readiness.
