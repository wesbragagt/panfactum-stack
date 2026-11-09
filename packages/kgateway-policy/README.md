<!-- cspell:ignore kgateway ExtProc GOMEMLIMIT GOMAXPROCS HSTS -->
# Header policy candidate for kgateway

This header-only gRPC external processor preserves the current Panfactum
Authentik Lua profile's distinction between missing and empty upstream CSP and
Permissions-Policy headers. The source policy is
[plugin.lua](../infrastructure/kube_ingress_nginx/plugin.lua); the caller must
provide its evaluated policy strings as public JSON configuration.

Status: isolated qualification candidate. This is not a complete ingress policy
implementation or a production installation. Experimental per-client request
limits are default-off and have bounded local qualification only. Request-size/
timeout enforcement, arbitrary CORS/override profiles, certificate
renewal and authenticated application sessions require separate implementation
and qualification. Do not silently replace those features with this processor.

The module pins Go 1.27.3 for qualified builds and patched gRPC/HTTP2 dependencies.
Binary vulnerability checks must inspect structured findings; a successful
JSON-mode scanner exit alone does not establish a clean result.

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
`GatewayExtension.spec.extProc.failOpen: false`. In the default header-only mode, body/trailer modes are `NONE`/`SKIP`.
The experimental request-limit mode instead requires both trailer modes `SEND`
while both body modes remain `NONE`; see the lifetime contract below. The default gRPC listener is `127.0.0.1:18083`; `/policy --check`
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


## Experimental per-client limits (default off)

`--request-limits` requires these additional public JSON string values:
`limit_rps`, `limit_rpm`, `limit_concurrency` and `limit_clients`. The local
candidate uses60/1000/60/8192. Both rate buckets use nginx1.27.1's thousandth-unit
leaky-debt arithmetic, integer millisecond clock and burst multiplier3, with no
delay queue. Both buckets and concurrency must accept atomically; rejected
requests do not add debt. Each identity is scoped to a normalized DNS authority
and canonical source IP. Source socket ports, DNS letter case, terminal dot and
authority ports do not split its quota. IP-literal authorities are unsupported.

Configure `GatewayExtension.spec.extProc.requestAttributes: [source.address]`.
The processor reads this Envoy attribute, never XFF/CF/client-supplied identity
headers. Missing or invalid identity returns429. Correct ListenerPolicy original
IP detection and actual connector-only networking are separate mandatory
qualifications; a successful local direct-source test is not production proxy
trust proof. Only one canonical-host route profile is qualified so far.

**Both trailer modes must be SEND.** Envoy otherwise closes its header-only RPC
after response headers, before a streaming request finishes. With trailer SEND
and body NONE, the tested HTTP/1.1 stream stays open until completion or client
cancellation; the server releases its concurrency slot when that RPC closes.
HEAD completion and cancellation are tested. Actual HTTP/2 and WebSocket
lifetime remain required before production enablement. Unexpected body messages
fail closed. No bodies are copied or logged by this processor.

The fixed identity capacity fails closed with429 when it cannot reclaim a fully
drained inactive entry; it never evicts an active client to admit a new one.
Capacity is per proxy, not globally shared across replicas, matching nginx's
per-controller scope. Exact overload/expiry behavior is an explicit operational
difference requiring capacity testing. No production module enables this flag.
The published header-only image predates this experimental implementation;
rebuild, scan and qualify both architectures again before distributing a new image.

## Experimental streaming body stage

`--max-request-bytes=N` enables declared Content-Length validation on the header
server and starts an independent body server at `127.0.0.1:18085`. Zero (the
default) leaves the second server disabled. `/policy --check --body-check`
checks both health services. The header stage keeps its existing scheme and
request-lifetime accounting; the body stage counts bytes without retaining or
replacing payloads. The qualified test cap is 10485760 bytes.

The body provider requires request headers SKIP, request body STREAMED, response
headers SEND, and all other modes NONE/SKIP. It permits only the NONE body-mode
override, returned after upstream status 101 **and** Upgrade websocket. A client
Upgrade header alone never disables the counter. Put the two providers at
separate explicit stages and verify both are enabled in effective route/vhost
xDS; a rendered TrafficPolicy alone is insufficient. kgateway 2.5.1 augmented
ExtProc policy merging is required by the local fixture.

Keep the 128KiB gRPC receive bound, 32KiB listener buffer, 64KiB HTTP/2 stream
window, and 1MiB HTTP/2 connection window together. The process retains the
32Mi request/64Mi limit and GOMEMLIMIT=48MiB, GOMAXPROCS=1. Native ListenerPolicy
local replies must provide plaintext/security headers when either processor is
unavailable. Do not increase message or memory limits to hide framing failures.

Local HTTP/1 and HTTP/2 boundary and early-forwarding tests are evidence for the
ordinary upload path only. Forged upgrade/tunnel framing, production ARM64,
concurrent memory saturation and complete timeout parity remain gates. Native
idle/connect policies belong to kgateway, not this binary; a 60s total request
deadline is not a substitute for a 60s between-packets timeout. This experimental
mode is not approved for production by the source commit or image build.
