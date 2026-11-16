## Usage

By default the proxy is exposed with ingress-nginx, and the upstream ingress uses the
`upstream_ingress_annotations` output to call the proxy as an auth subrequest.

### Gateway API mode

Set `gateway_api` when the cluster uses Gateway API instead of ingress-nginx. The module
then creates an `HTTPRoute` for `domain` and `path_prefix` on the given Gateway, and
oauth2-proxy forwards authenticated requests to `upstream_url`. Unauthenticated requests
get a 302 to the Vault OIDC authorize page. Remove any other route for the same host
and path, or it will compete with the proxy route. The `upstream_ingress_annotations`
output is unused in this mode.
