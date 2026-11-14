## Usage

No notes
### Discovery trust and scopes

`oidc_discovery_ca_pem` accepts an optional PEM CA bundle for HTTPS discovery;
its default `null` preserves system trust. `oidc_scopes` defaults to exactly
`["openid", "profile", "email"]`. For a private-CA Dex provider, for example:

```hcl
oidc_discovery_ca_pem = file("issuer-ca.pem")
oidc_scopes           = ["openid", "profile", "email", "groups"]
```

Dex requires the `groups` scope to return the claim consumed by the existing
`groups_claim = "groups"` mapping. These inputs replace caller-generated
resource overrides; no provider upgrade or group/policy default change is needed.

The actual module was exercised against OpenBao 2.7.2 and Dex **2.46.1** with
Vault provider **4.8.0**. Ten checks passed: CA-verified HTTPS discovery and JWKS,
actual module backend, authorization-code password login/callback, reader group
policy mapping, mapped KV read, admin denial for a reader, email claim mapping,
unmapped group denial and wrong-audience denial. HTTP sessions reproduced
redirects and forms; this was not a visual browser test, Authentik qualification,
or production SSO test. Existing-data migration and application-wide SSO remain
untested. No canary credentials, certificates or raw state are distributed here.
