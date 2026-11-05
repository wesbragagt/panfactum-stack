## Maintainer Notes

No notes.
Self-managed hosts can pass the existing OIDC provider and issuer through the shared service-account module. Default EKS discovery/IP restrictions remain unchanged. Explicit vault_replicas (default3), az_spread_required (defaulttrue), extra_helm_values (defaultempty) and nullable disable_mlock support a deliberate single-node topology. Raft join entries follow replica count; a single voter has no HA. The separate PDB retains maxUnavailable1, valid for one replica. For Raft, HashiCorp recommends disabling mlock on swap-disabled hosts. Preserve the pinned custom Panfactum image; the legacy vault_image_tag input does not select it. Bootstrap with wait=false, then enable wait after initialization. Never log initialization tokens or keys.
