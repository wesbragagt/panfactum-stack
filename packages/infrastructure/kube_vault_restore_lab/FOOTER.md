### Recovery laboratory contract

This optional module creates a separate namespace, PVC, private Service and
single-server StatefulSet for an isolated Vault/OpenBao rehearsal. It never
owns production Vault, its endpoint, data, Secrets, seal keys or existing namespace.
Default replicas are **zero**. It neither initializes nor restores a server.
Enabling the server requires an explicit assertion backed by live network AND
IAM evidence. Policy admission or readiness alone does not establish isolation.

The dedicated projected identity can Encrypt/Decrypt/Describe only the supplied
existing seal key. It has no S3, IAM, database or Kubernetes API permissions.
The Cilium policy permits DNS and exact regional KMS/STS FQDNs with matching TLS
SNI; it denies other egress by omission. Only labeled clients in the lab namespace
can connect to port 8200. Audit additive policies before use: another allow rule
can widen access. Copied static credentials and other persisted integrations still
require inspection and negative reachability tests before restoring production data.

Use an immutable server image. OpenBao requires declared, preinstalled AWS KMS and
AWS secrets plugins with signed-artifact hashes; runtime plugin downloads are
disabled. Packaging, actual plugin startup, original-version restore, cold unseal,
consumer behavior and rollback are separate acceptance tests. The original
Vault 1.14.7/KMS path remains outside OpenBao's official tested migration envelope.

Reserve 50m CPU/256Mi memory, a 512Mi memory limit, temporary workspace and a
dedicated encrypted recovery PVC within an explicit test window. The OnDelete
strategy intentionally avoids silently replacing a running restored process.
Restart, restore overwrite, cleanup and storage deletion need their exact scope
reviewed under the repository's destructive-action rules. Snapshots, tokens,
recovery keys and raw restored contents are never Terraform inputs or outputs.

The namespace owner also manages an aggregate quota: at most 448Mi requested
memory, 500m requested CPU, 1536Mi memory limits and four PVCs totaling 4Gi.
Additional instances must use create_namespace=false and the same namespace;
they must not create a second quota owner. Reserve capacity for the entire quota,
not just one server. Before a later gateway/secret-service overlap, lower the
quota to its separately verified budget and park unused test processes. Quota
denial is a stop condition, not permission to raise it or provision another node.
Retire every secondary instance before deleting the namespace owner's resources.

## Optional lab TokenReview bridge

`token_review_proxy_enabled` defaults to false. Enabling it creates a separate
32Mi-request verifier with only `create` permission on TokenReview. The restored
server receives only a private verifier egress exception, never API-server
network access or an API service-account token. Requests require a separate
private authorization Secret, exact review endpoint/type/audience, and allowed
lab ServiceAccount identities. Responses omit the reviewed token and untrusted
extra fields; request bodies and credentials are never logged. Runtime uses
verified Kubernetes CA TLS and refuses redirects. The authorization Secret is
operator-managed and must exist before enablement; its value is not an input.

Use this only for disposable lab auth mounts. It is not a general Kubernetes
API proxy, a production authentication replacement or a migration acceptance
claim. Network and effective RBAC must pass live positive/negative tests before
using it with restored data. The helper shares the namespace's aggregate quota;
its policy allows only DNS and the API, not AWS credentials, IAM or databases.
