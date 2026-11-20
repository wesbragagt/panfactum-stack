# kube_k9s_browser

k9s in the browser through ttyd, behind a Vault or OpenBao login (`kube_vault_proxy`). Each entry in `instances` deploys one instance in its own namespace. The Vault group decides who may open the instance. The instance's ServiceAccount decides what k9s may do.

| `read_only` | ClusterRoles | k9s mode |
| --- | --- | --- |
| `true` | `view` (no Secrets) plus get, list and watch on nodes | `--readonly` |
| `false` | `cluster-admin` | read-write |

## What the pod contains

The init container (`setup.sh`) installs everything into `/tools` for the node's architecture (arm64 or amd64):

| Tool | Source | Use |
| --- | --- | --- |
| ttyd 1.7.7, k9s v0.51.0, kubectl v1.35.10, hl 0.36.5 | GitHub and dl.k8s.io, sha256-pinned | Terminal, UI, `kubectl edit`, log formatting |
| vim, GNU less | Alpine 3.22 `apk fetch`, signature-checked | `KUBE_EDITOR`, log pager |

| File | Effect |
| --- | --- |
| `skins/catppuccin-mocha.yaml` | k9s skin, vendored from catppuccin/k9s. ttyd sets the matching xterm.js palette and the font (JetBrainsMono Nerd Font Mono, falling back to `monospace`). |
| `views.yaml` | Adds CLASS (`panfactum.com/class`), INSTANCE and ZONE columns to the node view |
| `plugins.yaml` | Shift-L in the pod and container views opens live logs through hl and less (`/tools/k9s-hl`) |
| vimrc (in `setup.sh`) | `habamax`, line numbers, 4-space indentation, incremental smart-case search |

## Shift-L log view

JSON and logfmt lines are formatted and colored. Other lines pass through unchanged. The view starts following the newest lines, and every key except Ctrl-C is ignored until you pause.

| Key | Action |
| --- | --- |
| Ctrl-C | Pause and freeze the screen. The stream keeps running. |
| Shift-F | Resume following |
| PageUp, PageDown | Scroll |
| `/`, `?`, `n`, `N` | Search forward or back, next or previous match |
| `&pattern` | Show only matching lines |
| `q` | Return to k9s |

To copy text, drag to select it and ttyd copies it on release. In k9s views, hold Shift while you drag.

## Prerequisites

- Vault or OpenBao with `vault_auth_oidc` applied, so that the `rbac-*` identity groups exist, and reachable at `vault_domain`.
- A Gateway API Gateway (for example from `kube_kgateway`) that serves `domain`, with DNS for `domain`. With `kube_kgateway`, add the hostname to `dns_hostnames`.
- Nodes that can pull `alpine:3.22` and reach github.com and the Alpine CDN.

## Usage

One caller deploys every instance. A typical pair is a read-only instance for readers and a read-write instance for admins:

```hcl
terraform {
  source = "${get_repo_root()}/forks/panfactum/packages/infrastructure//kube_k9s_browser"
}

dependencies { paths = ["../kube_vault", "../vault_auth_oidc", "../kube_kgateway"] }

inputs = {
  instances = {
    reader = {
      namespace           = "k9s-reader"
      domain              = "k9s.example.com"
      read_only           = true
      allowed_vault_roles = ["rbac-superusers", "rbac-admins", "rbac-readers"]
    }
    admin = {
      namespace           = "k9s-admin"
      domain              = "k9s-admin.example.com"
      read_only           = false
      allowed_vault_roles = ["rbac-superusers", "rbac-admins"]
    }
  }
  vault_domain = "vault.example.com"
  gateway_api  = { parent_name = "public", parent_namespace = "kgateway-system" }
  context_name = "my-cluster"
}
```

Every other input applies to all instances. The outputs `url` and `service_account` are maps keyed like `instances`. Each instance's resources live in the nested `instance/` module at `module.instance["<key>"]`, so renaming a key destroys and recreates that instance.

## Gotchas

- The first plan of a new caller fails with `metadata.0.labels ("<null>")`. `panfactum.hcl` generates the `pf` provider only after `.terraform.lock.hcl` lists `panfactum/pf`, and the first run writes that lock file. Plan again.
- `kube_vault_proxy` names its Secret `oauth2-proxy`, so two instances cannot share a namespace.
- The `panfactum.com/root-module` label is the caller directory name and is set on the pod templates. Renaming the caller or moving instances to another caller restarts the pods even when the state moves are exact.
- k9s's `c` (Copy) key cannot reach the browser clipboard. The pod has no clipboard, and ttyd 1.7.7 does not handle the OSC 52 fallback.
- k9s expands every `$VAR` in plugin args, so plugin shell logic belongs in a script such as `/tools/k9s-hl`.
- k9s shares its process group with plugins, so a Ctrl-C signal would quit k9s. `k9s-hl` disables the signal and has less read Ctrl-C as a key (`--intr=^C`).
- ttyd JSON-parses each `-t` value. Pass a font list as a JSON string, or ttyd keeps only the first name.

## Test

Without a session, `domain` returns 302 to `<vault_domain>/ui/vault/identity/oidc/provider/oauth2-proxy-*/authorize`:

```sh
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://k9s.example.com/
kubectl auth can-i delete pods -A --as system:serviceaccount:k9s-reader:k9s   # no when read_only
```

After login, the k9s header shows `Context: <context_name> [R]` when `read_only` is true and `[RW]` otherwise.
