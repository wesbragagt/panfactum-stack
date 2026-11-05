## Maintainer Notes

No notes.
Self-managed clusters may forward an existing OIDC provider ARN/issuer to the shared auth module. All defaults retain EKS discovery and source-IP restrictions. Explicit chart overrides support Kubernetes node metadata and non-SELinux hosts; set storage_class_mount_options=[] and override node volumes/mounts for Talos. Configure controller region and disable IMDS credential fallback explicitly. Snapshot operations require separately installed CRDs/controller. Empty extra_helm_values preserves existing chart configuration.
