# Local cost metrics backend

Small standalone Prometheus for OpenCost. Chart29.43.0/app3.16.0 is pinned from the
official prometheus-community chart index. One server requests512Mi (1Gi limit),
one kube-state-metrics64Mi, and one node-exporter per node32Mi. No Prometheus
Operator CRDs, Grafana, Alertmanager, Pushgateway, Thanos, Redis or AWS identity
are created. Config reloader is disabled; a chart config change must roll/restart
the server to load the changed config.

The dedicated cost-monitoring namespace disables Linkerd injection and scopes PSA
host-access allowance for node-exporter. Prometheus accesses kubelet/cAdvisor via
the Kubernetes API proxy using its projected token and the Kubernetes CA; it does
not disable kubelet TLS verification. Kube-state-metrics has explicit collectors
without Secrets. Only kubelet/cAdvisor, KSM, node-exporter, Prometheus and OpenCost
are scraped; honor_labels is enabled on every job.

Local retention is2d, capped at1500MB to leave room for WAL/head data on the2Gi
PVC. WAL/head and API cardinality may still exceed this budget; monitor disk and
memory. The independent PVC uses ebs-standard-retained and prevent_destroy. A
WaitForFirstConsumer class binds only after the server Pod is created. Retention
is not a backup or remote-write facility. A stopped sole node cannot collect
metrics; missing history cannot be reconstructed later.

The endpoint output is http://cost-prometheus-server.cost-monitoring.svc.cluster.local:80.
OpenCost defaults are expected at open-cost.open-cost.svc.cluster.local:9003.
There is no public ingress. Access through a loopback port-forward if necessary.
This provides a cost-data trial, not a substitute for the complete Panfactum
monitoring/alerting stack. The static server scrape config intentionally avoids
broad annotation discovery, and no business/application Secrets are read.

Verify without a cluster:

```sh
tofu init -backend=false
tofu validate
python tests/check_render.py
```

The checker evaluates the actual Terraform values template, verifies the pinned
chart archive digest, and inspects its rendered scheduling/storage/scrape/RBAC
contract. Live acceptance must check PVC binding, all six scrape jobs, actual
container/KSM/cost time series, Prometheus query APIs, and OpenCost allocation
results after enough history. The source assumes Kubernetes API proxy access to
kubelet metrics works on the deployed Talos version; live results remain to verify.
