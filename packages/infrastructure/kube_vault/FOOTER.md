## Maintainer Notes

No notes.
Self-managed hosts can pass the existing OIDC provider and issuer through the shared service-account module. Default EKS discovery/IP restrictions remain unchanged. Explicit vault_replicas (default3), az_spread_required (defaulttrue), extra_helm_values (defaultempty) and nullable disable_mlock support a deliberate single-node topology. Raft join entries follow replica count; a single voter has no HA. The separate PDB retains maxUnavailable1, valid for one replica. For Raft, HashiCorp recommends disabling mlock on swap-disabled hosts. Preserve the pinned custom Panfactum image; the legacy vault_image_tag input does not select it. Bootstrap with wait=false, then enable wait after initialization. Never log initialization tokens or keys.

## Opt-in OpenBao support

Set `secrets_engine = "openbao"` to select OpenBao Helm chart **0.30.7** and
OpenBao **2.7.2**, pinned to multi-platform image digest
`sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f`
at `ghcr.io/openbao/openbao`. The same image is available at Docker Hub;
`extra_helm_values.server.image.registry = "docker.io"` selects that mirror.
The packaged external plugins are **ARM64 only**: AWS KMS **0.1.1** and AWS
secrets **0.3.3**. Run this configuration on ARM64 nodes. A BusyBox **1.37.0**
init container downloads the release archives from GitHub, checks both archive
and executable SHA-256 hashes, and installs read-only plugins. Startup requires
network access to those releases. A read-only `/compat/vault` alias points at
`/bin/bao` for existing module bootstrap commands. This alias is not the
HashiCorp CLI; compatibility with the actual HashiCorp Vault CLI **1.14.7** was
also exercised against the canary.

The default remains `secrets_engine = "vault"`: the original two Helm values
entries, chart/image selection, `ha.hcl`, outputs, release/namespace `vault`,
`vault-active:8200` service and `/vault/data` layout are preserved. OpenBao adds
one overlay between common values and caller overrides. The OpenBao server
container is named `openbao`, including its VPA target.

For a fresh OpenBao deployment, explicitly configure:

- `vault_core_resources.vault_api_namespace = ""` for the root API namespace.
  The Kubernetes namespace remains `vault`.
- `vault_core_resources.aws_secrets_use_workload_identity = true` to use the
  pod's existing AWS workload identity for dynamic AWS credentials.
- On swap-disabled hosts, `disable_mlock = true` as appropriate for Raft.
- Provider-specific OIDC scopes and discovery CA through `vault_auth_oidc`
  when needed (see that module's notes).

Keep normal bootstrap ordering: initialize before enabling readiness waits.
Do not switch an existing Vault data volume by changing this flag alone.
Existing-data migration, rollback, and production SSO have **not** been validated.

### Validation and release scope

An isolated three-voter ARM64 canary exercised KMS auto-unseal, the real Vault
CLI 1.14.7, Vault provider 4.8.0, VSO 1.3.0 (KV refresh and encrypted cache restart
restore), KV, Kubernetes service-account auth, PKI, PostgreSQL/Redis dynamic
credentials, AWS dynamic credentials, OIDC, SSH signing and pod failover.
This is not a claim that all 19 applications were exercised. No production
identity provider or user was changed. See `vault_auth_oidc` for the narrower
Dex login proof and `vault_core_resources` for the provider workaround.

Local regression checks (Python 3, OpenTofu and Helm on PATH):

```sh
python3 -m unittest discover -s packages/infrastructure/kube_vault/tests -v
python3 -m unittest discover -s packages/infrastructure/vault_core_resources/tests -v
python3 -m unittest discover -s packages/infrastructure/vault_auth_oidc/tests -v
```

The Helm tests fetch the exact chart versions above and render real module
values with synthetic infrastructure outputs; they do not contact a cluster.
