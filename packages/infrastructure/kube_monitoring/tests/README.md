# Single-node preparation

Module defaults preserve the existing production replica counts, memory requests,
placement and Vault OIDC behavior. The four OIDC resources have moved addresses
so adding their default-enabled count does not recreate an existing deployment.
Turning OIDC off on an existing installation removes those resources: review that
plan as destructive. Basic authentication must stay enabled when OIDC is disabled.

Suggested starting caller inputs for an intentionally non-HA controller-only lab:

```hcl
grafana_oidc_enabled = false
grafana_basic_auth_enabled = true
ingress_enabled = false
thanos_bucket_web_enable = false
enhanced_ha_enabled = false
az_spread_required = false
operator_webhook_replicas = 1
prometheus_replicas = 1
alertmanager_replicas = 1
grafana_replicas = 1
thanos_query_replicas = 1
thanos_frontend_replicas = 1
thanos_store_gateway_replicas = 1
prometheus_memory_request_mb = 512
prometheus_memory_limit_mb = 768
kube_state_metrics_memory_request_mb = 64
kube_state_metrics_memory_limit_mb = 128
redis_replicas = 1
redis_allow_single_node = true
redis_minimum_memory_mb = 128
grafana_db_instances = 1
grafana_db_minimum_memory_mb = 500
grafana_db_pooler_minimum_memory_mb = 25
grafana_db_burstable_nodes_enabled = false
grafana_db_spot_nodes_enabled = false
grafana_db_controller_nodes_enabled = true
vpa_enabled = false
monitoring_enabled = false
panfactum_scheduler_enabled = false
pull_through_cache_enabled = false
```

Supply the existing self-managed OIDC provider ARN and issuer through
`oidc_provider_arn` / `oidc_issuer_url` (with the chosen subnet/IP restriction
inputs). These reach all five direct AWS identities and Grafana PostgreSQL.
Redis does not use an AWS role. Grafana remains accessible through its internal
service and port-forwarding with ingress disabled. Its PostgreSQL dependency and
Vault PKI/secrets dependencies remain required when Grafana OIDC is disabled.
CNPG, Redis/Vault secrets support, internal certificate issuers, retained EBS
storage and their CRDs must exist before a real deployment. This module creates
S3 storage and multiple PVCs; this is not an AWS-cost-free configuration.
The existing compactor disk defaults to 100Gi: choose a measured lab-specific
`thanos_compactor_disk_storage_gb` before planning rather than accepting it blindly.

With VPA enabled, `thanos_vpa_minimum_memory_mb` defaults to the original 1000Mi
floor. Initial requests for Thanos/Grafana remain 100Mi/130Mi limit; use
`thanos_extra_helm_values` / `prometheus_extra_helm_values` for component-specific
adjustments after measuring actual use. Small memory values are starting settings,
not capacity guarantees. The PostgreSQL module enforces its existing 500Mi floor.

Verification run from the fork root (Helm, Python and PyYAML required):

```sh
helm template monitoring kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 82.10.5 --namespace monitoring --kube-version 1.37.1 -f packages/infrastructure/kube_monitoring/tests/single-node-prometheus.yaml > /tmp/monitoring-render.yaml
helm template thanos oci://registry-1.docker.io/bitnamicharts/thanos --version 17.3.1 --namespace monitoring --kube-version 1.37.1 -f packages/infrastructure/kube_monitoring/tests/single-node-thanos.yaml > /tmp/monitoring-thanos-render.yaml
python packages/infrastructure/kube_monitoring/tests/check_chart_contract.py /tmp/monitoring-render.yaml /tmp/monitoring-thanos-render.yaml
```

Fixtures verify the pinned charts accept the selected replica/resource/OAuth
settings; they are not the module's full Terraform-evaluated values or its
post-render output. `tofu init -backend=false` and `tofu validate` also passed
with an isolated provider cache. No plan, live runtime compatibility, image
architecture check, AWS access, or resource readiness is established by these
local checks. Preserve the existing lightweight Prometheus/OpenCost deployment
until full monitoring is healthy and its scrape/data handoff is verified.
