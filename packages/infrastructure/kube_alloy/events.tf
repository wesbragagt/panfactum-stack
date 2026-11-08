# v1.1.0 watches core/v1 Events only; no pod/log or secret access needed.
resource "kubernetes_service_account_v1" "events" {
  count = var.kubernetes_events_enabled ? 1 : 0
  metadata {
    name      = "alloy-events"
    namespace = local.namespace
    labels    = module.util.labels
  }
}
resource "kubernetes_cluster_role_v1" "events" {
  count = var.kubernetes_events_enabled ? 1 : 0
  metadata { name = "alloy-events" }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}
resource "kubernetes_cluster_role_binding_v1" "events" {
  count = var.kubernetes_events_enabled ? 1 : 0
  metadata { name = "alloy-events" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.events[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.events[0].metadata[0].name
    namespace = local.namespace
  }
}
resource "kubernetes_config_map_v1" "events" {
  count = var.kubernetes_events_enabled ? 1 : 0
  metadata {
    name      = "alloy-events"
    namespace = local.namespace
    labels    = module.util.labels
  }
  data = { "events.alloy" = templatefile("${path.module}/events.alloy", { REDACTION_STAGES = local.redaction_stages }) }
}
resource "kubernetes_deployment_v1" "events" {
  count = var.kubernetes_events_enabled ? 1 : 0
  metadata {
    name      = "alloy-events"
    namespace = local.namespace
    labels    = module.util.labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = { app = "alloy-events" } }
    template {
      metadata {
        labels = merge(module.util.labels, { app = "alloy-events" })
        annotations = {
          "linkerd.io/inject" = "disabled"
          "checksum/config"   = sha256(kubernetes_config_map_v1.events[0].data["events.alloy"])
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.events[0].metadata[0].name
        security_context {
          run_as_non_root = true
          run_as_user     = 473
          run_as_group    = 473
          fs_group        = 473
        }
        container {
          name  = "alloy"
          image = var.kubernetes_events_image
          args  = ["run", "--storage.path=/var/lib/alloy", "--server.http.listen-addr=0.0.0.0:12345", "/etc/alloy/events.alloy"]
          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          readiness_probe {
            http_get {
              path = "/-/ready"
              port = 12345
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/alloy"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/alloy"
          }
        }
        volume {
          name = "config"
          config_map { name = kubernetes_config_map_v1.events[0].metadata[0].name }
        }
        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
  depends_on = [kubernetes_cluster_role_binding_v1.events]
}
