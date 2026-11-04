## Maintainer Notes

No notes.
### Self-managed clusters (Talos)

Supply `oidc_provider_arn` and `oidc_issuer_url` together to use an existing OIDC
issuer without querying EKS. The ARN must match the issuer and role account.
Custom trust requires the exact namespace/service-account subject and the
`sts.amazonaws.com` audience; it does not grant access to all service accounts.

Default EKS discovery and source-IP deny policies remain enabled. Optional
`cluster_subnet_ids` bypasses tag-based discovery when explicit subnet IDs are
known. An explicit `ip_restrictions_enabled=false` suppresses the additional IP
policies and their subnet queries, while retaining OIDC trust constraints. This
is needed for the current prototype: its public IP changes after scheduled
stop/start and its public-subnet egress does not pass through fck-nat. A static
allowlist of the NAT's EIP would deny its non-S3 requests. Do not opt out globally
or silently remove restrictions from existing roles. Existing EKS IP-policy
resource addresses are preserved with moved blocks.

The module does not create an issuer, signing keys, identity webhook or namespace.
For new service accounts, use `annotate_service_account=false` and set the output
annotations on the service account resource to avoid annotation ordering cycles.
No static AWS credentials are required.

Checks: `tofu init -backend=false`, `tofu validate`, and
`python3 tests/test_oidc.py`. The six offline tests evaluate the actual issuer,
lookup/resource gates and pairing/account preconditions. A full unchanged EKS
caller plan still needs its own regression verification.

Add-on modules must explicitly forward these inputs to their nested
`kube_sa_auth_aws` module. Setting similarly named root caller inputs does not
configure nested modules automatically.
