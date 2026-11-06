Run `python tests/check_chart_contract.py` with Helm and PyYAML available. This
renders the pinned chart twice and checks its actual endpoint environment,
ServiceMonitor toggle, exporter resources and pinned application image. It needs
registry access, but no cluster or AWS credentials. It does not prove the complete
Terraform module graph or Kubernetes runtime behavior.

Minimal caller inputs after provisioning a real Prometheus scraper:

```hcl
prometheus_endpoint = "http://prometheus.monitoring.svc:9090"
monitoring_enabled = false
network_cost_enabled = false
spot_data_feed_enabled = false
vpa_enabled = false
panfactum_scheduler_enabled = false
pull_through_cache_enabled = false
```

The bucket inputs may be omitted only when Spot feed is disabled. Existing callers
retain monitoring/network/Spot feed enabled by default; moved blocks preserve
resource addresses. Enabling network-cost still requires reviewing the existing
hardcoded destination CIDRs and privileged host mounts against the target cluster.
No new network-cost compatibility claim is made. The explicit Prometheus endpoint
must expose query APIs and scrape actual workload/KSM/OpenCost metrics; a healthy
OpenCost Pod with an empty Prometheus is not acceptance.
