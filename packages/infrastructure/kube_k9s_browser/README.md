# kube_k9s_browser

k9s in the browser through ttyd, behind a Vault or OpenBao login (`kube_vault_proxy`). Each call deploys one instance in its own namespace. The Vault group decides who may open the instance. The instance's ServiceAccount decides what k9s may do.

| `read_only` | ClusterRoles | k9s mode |
| --- | --- | --- |
| `true` (default) | `view` (no Secrets) plus get, list and watch on nodes | `--readonly` |
| `false` | `cluster-admin` | read-write |

The init container (`setup.sh`) installs ttyd 1.7.7 and k9s v0.51.0 for the node's architecture (arm64 or amd64) and checks their sha256. It also unpacks Alpine 3.22 `vim` with `apk fetch` (signature-checked) and sets it as `KUBE_EDITOR`. `views.yaml` adds CLASS (`panfactum.com/class`), INSTANCE and ZONE columns to the node view.

## Prerequisites

- Vault or OpenBao with `vault_auth_oidc` applied, so that the `rbac-*` identity groups exist, and reachable at `vault_domain`.
- A Gateway API Gateway (for example from `kube_kgateway`) that serves `domain`, with DNS for `domain`. With `kube_kgateway`, add the hostname to `dns_hostnames`.
- Nodes that can pull `alpine:3.22` and reach github.com and the Alpine CDN.

## Usage

One caller per instance. A typical pair is a read-only instance for readers and a read-write instance for admins:

```hcl
terraform {
  source = "${get_repo_root()}/forks/panfactum/packages/infrastructure//kube_k9s_browser"
}

dependencies { paths = ["../kube_vault", "../vault_auth_oidc", "../kube_kgateway"] }

inputs = {
  namespace           = "k9s-reader"
  domain              = "k9s.example.com"
  vault_domain        = "vault.example.com"
  gateway_api         = { parent_name = "public", parent_namespace = "kgateway-system" }
  read_only           = true
  allowed_vault_roles = ["rbac-superusers", "rbac-admins", "rbac-readers"]
  context_name        = "my-cluster"
}
```

For the admin instance, set `read_only = false`, `allowed_vault_roles = ["rbac-superusers", "rbac-admins"]` and a different `namespace` and `domain`.

## Gotchas

- The first plan of a new caller fails with `metadata.0.labels ("<null>")`. `panfactum.hcl` generates the `pf` provider only after `.terraform.lock.hcl` lists `panfactum/pf`, and the first run writes that lock file. Plan again.
- `kube_vault_proxy` names its Secret `oauth2-proxy`, so two instances cannot share a namespace.

## Test

Without a session, `domain` returns 302 to `<vault_domain>/ui/vault/identity/oidc/provider/oauth2-proxy-*/authorize`:

```sh
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://k9s.example.com/
kubectl auth can-i delete pods -A --as system:serviceaccount:k9s-reader:k9s   # no when read_only
```

After login, the k9s header shows `Context: <context_name> [R]` when `read_only` is true and `[RW]` otherwise.
