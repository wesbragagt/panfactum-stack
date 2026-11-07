## Usage

No notes
### Self-managed clusters and private Workflows-only deployment

Defaults retain Vault SSO, Events and EKS discovery. Set `events_enabled = false`
for Workflows alone and `sso_enabled = false` for Kubernetes bearer-token client
access. Disable ingress until an authenticated public exposure flow is verified.
No Redis or Argo CD installation is required. The Workflows chart remains pinned
by `argo_workflows_helm_version`; these switches do not upgrade it.

For custom AWS identity, supply both OIDC inputs and explicit subnet/IP policy
settings. The module owns an `argo-workflow` service account and a bucket-scoped
IRSA role; use that account in workflow specs. Providers managing service accounts
must ignore only `^eks[.]amazonaws[.]com/role-arn$`, whose annotation belongs to
`kube_sa_auth_aws`. Namespace labels and Linkerd injection are explicit overrides.

For a single controller database, set `db_controller_nodes_enabled = true`,
`db_node_selector` to the controller's required label, `db_spot_nodes_enabled = false`,
and `db_az_spread_required = false`. Tolerations alone do not require placement.
Set `db_backups_force_delete = false` to retain backups. Database storage remains
owned by the existing PostgreSQL module; never recreate it to change placement.
Use explicit component memory bounds and server replicas appropriate to capacity.
