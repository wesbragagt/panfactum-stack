# Talos validation and hook prerequisite

Run `tofu init -backend=false`, `tofu validate`, and
`python tests/check_chart_contract.py` with Helm/PyYAML available. The checker
renders exact chart9.1.3 with Kubernetes1.37.1 and verifies location names/regions,
cleanup behavior, no node agent/static credential Secret, and included CRDs. It
does not perform a Terraform plan or a live backup/restore.

For retained homelab backups, set `cleanup_crds_enabled=false`. Its default remains
true only for compatibility; the pre-delete hook deletes the Velero CRDs and is
destructive. Four explicit OIDC inputs now reach kube_sa_auth_aws. CSI prerequisites
remain external snapshot CRDs/controller plus a working EBS CSI snapshotter.

## Required hook-image decision

The pinned chart's upgrade hook renders `docker.io/bitnamilegacy/kubectl:1.37` on
Kubernetes1.37.1. Registry inspection on2026-11-05 returned manifest unknown.
`rancher/kubectl:v1.37.1` was also unavailable. Do not deploy the default hook on
this Kubernetes version or assume another image tag contains the right binaries.
The hook runs `/bin/sh` and copies both `sh` and `kubectl` into the Velero image;
a replacement must include both, work on ARM64, and have copied binaries whose
interpreters/shared libraries are available inside the Velero container. Merely
finding an ARM64 image index does not establish that copy-and-run contract.

`extra_helm_values.kubectl.image` can supply a verified helper repository/tag/digest.
Do not change EKS defaults by guessing one. For an initial install only,
`extra_helm_values = { upgradeCRDs = false }` uses the CRDs packaged in chart9.1.3;
the render test verifies they are present. Helm does not upgrade files under
`crds/` on later releases, so a future CRD upgrade must be handled separately in a
reviewed deployment. Disabling the hook is not a long-term CRD-upgrade strategy.

The server has no host paths when node-agent remains disabled; filesystem backup
and data-mover claims are not made. Explicit AWS region is already passed into
both storage/snapshot locations. The module creates a dedicated private S3 bucket
(default SSE-S3), not the existing Talos etcd/Vault snapshot bucket. Backup success,
snapshot cleanup, encrypted volume restoration and application-level consistency
must be demonstrated before treating this as recovery acceptance.
