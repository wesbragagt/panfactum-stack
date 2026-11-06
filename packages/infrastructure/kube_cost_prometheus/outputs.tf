output "prometheus_endpoint" {
  description = "Cluster-local Prometheus query URL for OpenCost"
  value       = "http://cost-prometheus-server.${var.namespace}.svc.cluster.local:80"
}
output "namespace" { value = var.namespace }
