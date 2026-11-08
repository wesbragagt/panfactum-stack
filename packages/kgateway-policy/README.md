<!-- cspell:ignore kgateway ExtProc GOMEMLIMIT GOMAXPROCS HSTS -->
# Header policy candidate for kgateway

This header-only gRPC external processor preserves the current Panfactum
Authentik Lua profile's distinction between missing and empty upstream CSP and
Permissions-Policy headers. The source policy is
[plugin.lua](../infrastructure/kube_ingress_nginx/plugin.lua); the caller must
provide its evaluated policy strings as public JSON configuration.

Status: isolated qualification candidate. This is not a complete ingress policy
implementation or a production installation. Rate and connection limits,
request-size/timeout enforcement, arbitrary CORS/override profiles, certificate
renewal and authenticated application sessions require separate implementation
and qualification. Do not silently replace those features with this processor.

The processor requests headers only, keeps request scheme state inside each
gRPC stream, and emits no request/response/header/body logs. It preserves
existing CSP and Permissions-Policy values, including empty and repeated values;
it adds missing defaults according to status and content type. Empty
Content-Type follows nginx's special absent-field behavior. The HTML-specific
frame/XSS/referrer fields and HTTPS HSTS match the selected profile. Additional
native header modifiers remain owned by the route policy. Pair removal of the
Server header with `ListenerPolicy` HTTP setting
`serverHeaderTransformation: PassThrough`; Envoy otherwise re-adds its own value
after the route modifier.

Use a loopback backend in the same proxy Pod and explicitly configure
`GatewayExtension.spec.extProc.failOpen: false`. Body and trailer modes must be
`NONE`/`SKIP`. The default gRPC listener is `127.0.0.1:18083`; `/policy --check`
checks its standard gRPC health service. No Kubernetes or AWS identity, writable
filesystem, shell, runtime downloads or external network dependency is required.

Required JSON keys are `csp`, `csp_non_html`, `permissions_policy`,
`x_frame_options`, `x_xss_protection` and `referrer_policy`; the evaluated fixture
also includes `cross_origin_resource_policy` for the native modifier. These
values cannot contain CR/LF/NUL. This profile does not expose enable/override
flags for generic applications.

```sh
go test -race ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath \
  -ldflags '-s -w -buildid=' -o build/policy .
cp Dockerfile build/Dockerfile
docker build -t YOUR_UNIQUE_QUALIFICATION_TAG build
```

The scratch image runs as UID/GID 65532. Qualification uses a read-only root,
dropped capabilities, 32Mi memory request / 64Mi limit, `GOMEMLIMIT=48MiB` and
`GOMAXPROCS=1`. A real local kgateway/Envoy run must validate the generated
sidecar overlay, loopback HTTP/2 cluster, fail-closed behavior and actual emitted
headers. Version/hash-only ARM64 execution does not prove policy translation.
