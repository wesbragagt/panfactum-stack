# Experimental RustyBouncer backend

`pooler_implementation = "pgbouncer"` remains the default, retaining CNPG Pooler
ownership, existing service names, tuning and manifests. No installed caller has
been switched. `"rustybouncer"` selects an independently managed Deployment,
ConfigMap and Service for the writable endpoint, using the existing pooler labels,
scheduling, replica count (`pg_instances`), PDB and service/port outputs. VPA targets
the selected implementation and optional PodMonitor scrapes RustyBouncer metrics.
The read-only label output also now selects the actual `r` pooler.

## Verified source and image contract

Reviewed 2026-11-14 against canonical source
[Forgejo wesbragagt/rustybouncer](https://forgejo.dory-pentatonic.ts.net/wesbragagt/rustybouncer),
commit `d9d985fbdfaa66e8f0ba9e9b54ae31c4758d5fe0`; local checkout and remote HEAD
matched. The requested GitHub URL returned 404. This supersedes the review of
`1163fba1e077f15003efac16c775d6f42080588f`, which lacked TLS/auth-query support.

`rustybouncer_image` must be a caller-supplied immutable `repository@sha256:…`
reference built from this source or a verified compatible successor. Its entrypoint
must accept one positional TOML filename. There is no default public image.
The earlier ARM64 experimental ECR digest
`sha256:79c63e1ea41b4d1a4b7d72789ee62baa1bf554a58c12f1460206ac28243c5e03`
contains **1163fba**, so it cannot run this integration. Build/publication of a
compatible image is required; a correctly formatted digest alone cannot prove
source compatibility. A compatible experimental ARM64 candidate from `d9d985f`
has now been published and independently inspected:

```text
668112512252.dkr.ecr.us-east-2.amazonaws.com/homelab-experimental/rustybouncer@sha256:5d33011a4a20d57aeae9715b8b53f244fd2f2488438f730e7a88e5eedb82c2ae
```

Its source/archive/recipe hashes, 71 passing native release unit tests and ARM64
cross-build are retained in `evidence/rustybouncer-live/`. This candidate does not
establish release qualification. `apps/rustybouncer-build/` retains the older
cluster build recipe; the candidate's local cross-build recipe is in the evidence.

Set `rustybouncer_image_pull_secrets` for existing namespace-local pull credentials,
or authorize ECR pulls through the nodes' existing credential provider. The module
does not publish images or create registry credentials. Both router and readiness
images must support the selected node architecture.

The generated TOML follows `src/main.rs`, `src/auth.rs` and `src/transport.rs` at
the reviewed SHA. The listener is `0.0.0.0:5432`; it requires frontend TLS and
SCRAM-SHA-256. Backend TLS verifies the mounted CA and the CNPG writable service
DNS name. It never enables trust authentication. Only the CNPG `-rw` Service is
configured: DNS follows current primary membership and instance replacement,
avoiding static Pod ordinals. Existing sockets may retain the previous primary
until they error or expire; the router does not see a distinct node index on a
Service-level promotion. No replica routing or application-query replay is enabled
(`read_max_attempts = 1`). Validate promotion behavior for the intended workload.

## Credentials, TLS rotation and readiness

The module provisions `rustybouncer_auth` independently of CNPG Pooler CRs through
the existing awaited schema-init Job. That Job runs when RustyBouncer is selected,
even with no extra schemas, and runs against fresh or restored databases. Its
RustyBouncer job name includes the SQL hash so changes recreate the initializer.
PgBouncer's existing job name and exact SQL command remain unchanged by default.

The role is a login role without a password or application grants. Its dedicated
cert-manager Certificate has CN `rustybouncer_auth` and a client Secret named
`<cluster>-rustybouncer-client`; it remains managed and renewed when there are no
CNPG Pooler objects. An explicit `hostssl all rustybouncer_auth all cert` HBA rule
requires that certificate. Only the public CA certificate and the needed leaf
certificate/key are mounted into the router. It does not mount the CA signing key
or Vault reader password. Issuers must use the same trusted client CA already
required by this module's other cert-manager-issued CNPG certificates.

The Job creates `public.rustybouncer_user_search(text)` in `app`, owned by the
durable `postgres` role (explicit `ALTER FUNCTION ... OWNER TO postgres`), with
`SECURITY DEFINER SET search_path =
pg_catalog`. It returns only the requested role's SCRAM verifier if the role can
log in and its validity has not expired. It grants EXECUTE to `rustybouncer_auth`
and revokes EXECUTE from PUBLIC, reader, writer and per-schema reader/writer roles
after the existing broad function grants. It also revokes those application roles
from the legacy `public.user_search(text)` when that function exists, so schema-wide
grants cannot reopen a second verifier path. The lookup role itself cannot read
`pg_authid` directly. Ordinary application credentials never receive verifier
access from this new function. Keep the database superuser/schema administration
boundary trusted, as with the existing `user_search` function.

Vault reader/admin and per-schema reader/admin credential issuance refresh broad
function grants. When RustyBouncer is selected, each of those four creation paths
ends with guarded revokes for both verifier functions in the issuance transaction.
The guards permit fresh bootstrap before either function exists. This matters on
every lease rotation: initializer-only revokes are reopened by later broad grants.
The default PgBouncer credential statement arrays remain unchanged.

Application connections authenticate using their own Vault/OpenBao dynamic
credentials, and backend connections retain each client's PostgreSQL identity and
SQL privileges. The probe/lookup role never executes application SQL. New logins
query verifiers afresh, including after password rotation, role expiry or role
removal. Revocation does not terminate already established sessions; verify the
required lease/session behavior separately.

A separate `sql-readiness` container uses the module's CNPG PostgreSQL image and
`psql`. Custom PostgreSQL images must include `/bin/sh`, `sleep`, `cat` and `psql`.
Its readiness exec rereads username/password from the existing rotating Vault
reader Secret, connects to **this Pod** using `hostaddr=127.0.0.1` with the real
service hostname, `sslmode=verify-full`, and executes `SELECT 1` in `app` through
RustyBouncer. It receives no lookup certificate. This gates Pod readiness on actual
TLS, authentication and usable SQL routing, without depending on Service endpoints
or granting verifier privileges to the reader. The extra container requests
10m CPU/32Mi memory and has a 64Mi memory limit.

Whole-directory Secret mounts receive projected updates; there are no `subPath`
mounts. The reviewed binary rereads TLS PEM files on each new connection, including
probes/lookups. Existing TLS sessions keep negotiated credentials until closed;
`pool_idle_timeout_ms` and `pool_server_lifetime_ms` bound idle pooled retention.
TOML changes roll the Deployment via its configuration hash. There is no TOML hot
reload. The Deployment opts out of Panfactum Reloader's global `autoReloadAll` so
rotating mounted Secrets does not force a rollout. Server certificate SANs already include the unchanged writable pooler
service name. PostgreSQL still enforces TLS 1.3 on backend connections.

## Example for a new isolated cluster

```hcl
inputs = {
  pooler_implementation        = "rustybouncer"
  pgbouncer_read_only_enabled  = false
  pgbouncer_read_write_enabled = true

  # Supply the actual published digest for d9d985f or a verified successor.
  rustybouncer_image = "registry.example/team/rustybouncer@sha256:<actual-64-hex-digest>"
  rustybouncer_image_pull_secrets = ["registry-pull"]
  rustybouncer_config = {
    pool_mode         = "session"
    max_clients       = 1000
    pool_size         = 16
    max_pool_backends = 64
  }
}
```

Replace the placeholder digest; it intentionally fails validation. Session and
transaction modes are accepted; statement pooling and replica-only `r` endpoints
are unavailable. Selecting RustyBouncer while `pgbouncer_read_only_enabled = true`
fails a resource precondition. `rustybouncer_config` validates positive integer
limits/timeouts and pool-size bounds. It owns protocol tuning independently:
`pgbouncer_pool_mode` and other PgBouncer protocol knobs do not configure this
implementation. Existing `pgbouncer_*_enabled` flags and minimum/maximum CPU/memory
inputs remain the shared endpoint/resource controls. Resource requests/limits
retain the module's existing VPA behavior.

## Migration and remaining limits

Changing an existing cluster's selection destroys CNPG Pooler CRs and introduces
same-name Services with new ownership. CNPG cleanup can delete its old Service;
do not perform an in-place traffic cutover by applying this flag alone. First
exercise a separately named isolated cluster/canary, prepare a maintenance window,
review endpoint cleanup/adoption and rollback, then plan in tmux. Any destructive
plan requires explicit confirmation under the repository rules. Existing callers
have not been cut over; candidate publication and isolated manifest-based live
acceptance are recorded separately in `evidence/rustybouncer-live/`.

The source still has no graceful transaction drain or SIGTERM handler. A 5-second
Kubernetes preStop sleep allows endpoint propagation; it does **not** drain active
transactions. Rolling replacement allows a ready surplus Pod, but connections on
the retiring Pod can be interrupted. Applications must handle disconnects and
uncertain commit outcomes without unsafe retries. PgBouncer's shell drain hook is
not copied into the Rust image. Other gaps include replica-only semantics, TOML
reload, SCRAM channel-binding PLUS, PgBouncer admin commands and release-wide
conformance. This is an experimental RW integration, not production/release parity.

## Verification

Recorded acceptance on **2026-11-14**: **71 native unit tests**, **11 mocked
module plan cases**, and **56 live/preflight/cleanup assertions passed** against
the compatible ARM64 digest above. The live assertions include TLS failures,
SCRAM, SQL/prepared queries, backend reuse, privilege restrictions, projected
certificate renewal and actual Vault credential rotation/revocation. They are
an aggregate of retained fixture runs, not full project conformance.

Testing found and fixed verifier grants being reopened by credential issuance
and Reloader restarting the pooler on Secret rotation. All owned fixtures and
leases were removed, prior database HBA/function ACLs restored, and PVC/PV
identities preserved. The installed canary remains on PgBouncer; its final plan
has no resource or output changes. No full module deployment or caller cutover
was performed. See the
[live acceptance report](../../../../../evidence/rustybouncer-live/README.md)
for exact coverage, retained failures and cleanup evidence.

An additional [live feature/load run](../../../../../evidence/rustybouncer-features/README.md)
passed 21 feature cases and 198,464 successful operations over four minutes,
including live transaction pooling, replica Pod replacement, primary Pod deletion
with external PostgreSQL promotion, router Pod deletion/reconnection, split-brain
refusal and passthrough COPY. All 30,346 acknowledged writes survived exactly
once; one additional write committed with an uncertain client outcome. The
fixture was removed and existing PVC identities preserved. It used isolated
trust/plaintext endpoints and emptyDir storage, independently of the earlier
TLS/SCRAM test. Full module deployment, CNPG-operator-driven failover and graceful
shutdown during active transactions remain untested.

Run from the module directory:

```sh
python3 tests/test_pooler_render.py
# Optionally compare manifests/SQL to the main.tf saved before this change:
python3 tests/test_pooler_render.py --baseline-main /path/to/previous-main.tf
# Additional private Unix-socket PostgreSQL SQL/privilege fixture:
python3 tests/test_pooler_render.py --postgres-bin /path/to/postgresql/bin
```

The provider-mocked harness evaluates copied production HCL expressions using
OpenTofu, with child outputs and a cluster ID supplied as fixtures. It exercises
defaults, opt-in RW resources, session/transaction modes, disabled resources,
monitoring/VPA, image/config rejection and replica-only rejection. Python parses
the rendered TOML and checks credential isolation, projected TLS mounts, loopback
SQL readiness and verifier-function privilege restrictions. The optional baseline
check compares normalized PgBouncer Pooler/VPA/PDB manifests and the exact schema
SQL command, schema-init Job name/count and four Vault credential creation arrays
across five endpoint/VPA combinations. It removes resource dependency
edges from the fixture, so it does not establish provider ordering or live behavior.
The private PostgreSQL fixture validates fresh and repeated initialization, durable
function ownership, fixed search_path, both verifier paths' application privilege
restrictions after all four actual credential creation sequences, fresh bootstrap
before the verifier functions exist, and expired/NOLOGIN/missing-role rejection. It starts only a temporary
local server with TCP listening disabled and stops it before removing its files.

Before any application cutover, retain evidence against the actual immutable image
for both-hop TLS/hostname failures and renewal, real Vault user privileges/expiry/
revocation, prepared statements, backend reuse, outage readiness/recovery, CNPG
promotion/replacement and active-transaction rollouts. Run the RustyBouncer project's
required conformance/release scope with zero failures/errors/skips; focused module
render tests do not establish that acceptance. Consult the retained live evidence
for the exact manifest fixture coverage and remaining full-module deployment gaps.
