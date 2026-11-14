## Usage

No notes
Self-managed clusters can explicitly set aws_secrets_use_workload_identity=true to use the Vault pod SDK web identity and attach scoped vault-* user management permissions to its existing role. This creates no bootstrap IAM user/access key. The default remains the existing static-root-credential path, with moved blocks preserving addresses. This is AWS SDK credential sourcing supported by the pinned open-source Vault version, not Enterprise plugin WIF.

### Vault API namespace and OpenBao

`vault_api_namespace` controls only the VSO Helm values
`controller.manager.clientCache.storageEncryption.namespace` and
`defaultAuthMethod.namespace`. Its default is the legacy `"vault"` value.
Set `vault_api_namespace = ""` for OpenBao's root namespace; it does not change
Kubernetes placement or the `vault-active.vault.svc.cluster.local:8200` address.
This replaces the canary's two Helm `set` overrides with one reusable input.

### Pinned Vault provider AWS username template workaround

Vault provider **4.8.0** omits `username_template` from the AWS backend update
trigger. A template-only edit may therefore fail to update the server; this
also affects Vault and is not OpenBao-specific. Keep the provider pin unchanged.
If needed, manage the non-secret root fields with an existing
`vault_generic_endpoint` alongside the backend, ordered after it:

```hcl
resource "vault_generic_endpoint" "aws_root_template" {
  path                 = "${vault_aws_secret_backend.aws.path}/config/root"
  disable_delete       = true
  ignore_absent_fields = true
  data_json = jsonencode({
    region            = data.aws_region.current.region
    username_template = trimspace(local.aws_username_template)
  })
  depends_on = [vault_aws_secret_backend.aws]
}
```

Use the actual backend and region references in the consuming configuration;
these resource names illustrate the pattern, not additional module inputs.
Keep the template newline-free and do not include static credentials in this
resource. The ARM64 canary exercised this managed endpoint workaround. It does
not justify upgrading providers or changing existing credential defaults.
