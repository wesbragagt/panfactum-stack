terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "2.35.0" }
    helm       = { source = "hashicorp/helm", version = "3.1.1" }
  }
}

resource "kubernetes_namespace_v1" "cost_monitoring" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "cost-monitoring"
      # node-exporter needs host networking/PID and read-only host paths.
      # Scope this exception to the dedicated monitoring namespace only.
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
    annotations = { "linkerd.io/inject" = "disabled" }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "prometheus" {
  metadata {
    name      = "cost-prometheus-data"
    namespace = kubernetes_namespace_v1.cost_monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name
    resources { requests = { storage = "2Gi" } }
  }
  # WaitForFirstConsumer needs the Helm-created Pod before EBS can bind.
  wait_until_bound = false
  lifecycle { prevent_destroy = true }
}

# Chart29 defaults to direct kubelet scraping and does not grant nodes/proxy.
# Only GET is needed for the two metrics paths configured through the API.
resource "kubernetes_cluster_role_v1" "api_proxy" {
  metadata { name = "cost-prometheus-api-proxy" }
  rule {
    api_groups = [""]
    resources  = ["nodes/proxy"]
    verbs      = ["get"]
  }
}
resource "kubernetes_cluster_role_binding_v1" "api_proxy" {
  metadata { name = "cost-prometheus-api-proxy" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.api_proxy.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "cost-prometheus"
    namespace = kubernetes_namespace_v1.cost_monitoring.metadata[0].name
  }
}

resource "helm_release" "prometheus" {
  name            = "cost-prometheus"
  namespace       = kubernetes_namespace_v1.cost_monitoring.metadata[0].name
  repository      = "https://prometheus-community.github.io/helm-charts"
  chart           = "prometheus"
  version         = var.prometheus_chart_version
  atomic          = var.wait
  cleanup_on_fail = var.wait
  wait            = var.wait
  wait_for_jobs   = true
  max_history     = 5
  values = [templatefile("${path.module}/values.yaml.tftpl", {
    namespace          = var.namespace
    storage_class_name = var.storage_class_name
  }), yamlencode(var.extra_helm_values)]
  depends_on = [kubernetes_persistent_volume_claim_v1.prometheus, kubernetes_cluster_role_binding_v1.api_proxy]
}
