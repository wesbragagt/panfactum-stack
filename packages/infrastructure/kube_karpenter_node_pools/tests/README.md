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

Talos must register with the temporary karpenter.sh/unregistered:NoExecute taint
in KubeletConfig.config.registerWithTaints, use FQDN registration for AWS CCM
instance discovery, and enable external cloud provider mode. Do not put this
registration taint in persistent KubeNodeConfig.taints (Talos would re-add it).
The worker config's KubeNodeConfig labels and taints are removed so Karpenter
applies each pool's own. Startup taints match EKS: the Cilium agent and the
kube_linkerd remove-taint sidecar on linkerd-cni clear them.

Worker userData is sensitive and must contain only worker join configuration,
not private CA/service-account signing keys or control-plane data. SOPS protects
the caller's checked-in source; AWS user-data/launch templates, Terraform state,
and the EC2NodeClass still contain join credentials and require access controls.
Do not print raw plans, state, kubeconfigs or bootstrap YAML. The user_data output
is now explicitly sensitive for both branches.

Validation: `env -i HOME=$HOME PATH=$PATH tofu test`. tests/eks_unchanged.tftest.hcl
pins the EKS manifests by hash; tests/talos_node_pools.tftest.hcl checks the Talos
pool set. Live acceptance requires a Ready NodeClaim/Node per pool with matching
AWS providerID, startup taint removal and Cilium readiness.
