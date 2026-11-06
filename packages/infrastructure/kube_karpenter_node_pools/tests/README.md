# Talos worker path

`cluster_type=eks` preserves the original Bottlerocket resources. `moved.tf` moves
all original resource/module/data addresses to their indexed equivalents so
adding the Talos branch does not recreate an existing EKS deployment. Switching
an existing EKS caller to Talos is a migration that can destroy its old pools;
inspect the full plan and obtain approval. Homelab uses a new caller/state.

The opt-in Talos path creates one Custom EC2NodeClass and one Spot-only NodePool.
It uses a pinned architecture-specific Talos AMI, existing instance profile,
private subnet/SG IDs, encrypted gp3 root and IMDSv2/hop1. A 4-CPU/16Gi limit with
2-CPU and4–8Gi instance requirements represents the initial two-worker budget.
Karpenter resource limits are eventually consistent during parallel provisioning;
observe actual capacity rather than treating them as an AWS account hard quota.

Talos must register with the temporary karpenter.sh/unregistered:NoExecute taint
in KubeletConfig.config.registerWithTaints, use FQDN registration for AWS CCM
instance discovery, and enable external cloud provider mode. Do not put this
registration taint in persistent KubeNodeConfig.taints (Talos would re-add it).
Only the active Cilium startup taint is configured; Linkerd CNI is not compatible
with this Talos host and has no startup-taint remover here.

Worker userData is sensitive and must contain only worker join configuration,
not private CA/service-account signing keys or control-plane data. SOPS protects
the caller's checked-in source; AWS user-data/launch templates, Terraform state,
and the EC2NodeClass still contain join credentials and require access controls.
Do not print raw plans, state, kubeconfigs or bootstrap YAML. The user_data output
is now explicitly sensitive for both branches.

Validation: backend-disabled init and OpenTofu validate pass. Live acceptance
requires a Ready NodeClaim/Node with matching AWS providerID, taint removal,
Cilium readiness, application DNS/TLS and eventual empty-node termination.
The existing on-demand controller and EKS defaults are not changed by creating
this new state/caller. No idle worker minimum, periodic expiry or underutilized
consolidation is enabled; only empty nodes consolidate after60seconds.
