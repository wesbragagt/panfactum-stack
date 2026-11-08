### Operational contract

This module adds recurring Raft snapshots to an **existing** Vault-compatible
server and private SSE-KMS S3 bucket. It never owns the namespace, Vault server,
storage, seal keys, bucket policy or retention lifecycle. It creates no workers.
An existing Kubernetes auth mount and digest-pinned image containing bash, curl,
jq, AWS CLI and sha256sum are required. AWS CLI must support PutObject IfNoneMatch.

The dedicated ServiceAccount gets no Kubernetes API RBAC. Two projected tokens
have separate Vault and STS audiences. The scoped Vault role can read snapshots,
inspect its own token/capabilities and revoke itself, with a ten-minute maximum
TTL and no default policy. The AWS role can put/get only its dedicated prefix and
use only the supplied S3 encryption key through S3; it cannot delete objects or
use the Vault seal key. Plaintext credentials are not Terraform inputs/outputs.

Every job verifies snapshot-read/KV-deny capabilities, uses a unique create-only
object key and explicit required KMS key, then checks encryption metadata and a
downloaded SHA256. Tokens are passed through stdin rather than process arguments;
snapshot files are private ephemeral workspace files and removed on exit.

Reserve 25m CPU/256Mi requested memory plus up to twice max_snapshot_mb workspace
before installation. The module uses a non-root, read-only container and does not
rely on the pod-identity webhook. Check power windows and time_zone. Forbid avoids
overlapping scheduled runs; an operator-created manual Job can still overlap.

Snapshot existence and checksum verification are **not** restore proof. Rehearse
original-version recovery with enforced network/IAM isolation before starting a
restored lease manager. Retention and recurring failure alerting remain explicit
operator responsibilities. Deleting this module must not remove stored snapshots.
