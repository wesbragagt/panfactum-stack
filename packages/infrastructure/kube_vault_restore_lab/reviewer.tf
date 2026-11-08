locals {
  reviewer_name = "${var.name}-reviewer"
  reviewer_labels = {
    "app.kubernetes.io/name"                   = local.reviewer_name
    "app.kubernetes.io/part-of"                = "vault-migration-lab"
    "migration-role"                           = "token-review-proxy"
    "panfactum.com/pull-through-cache-enabled" = "false"
  }
}

resource "kubernetes_service_account_v1" "reviewer" {
  count = var.token_review_proxy_enabled ? 1 : 0
  metadata {
    name      = local.reviewer_name
    namespace = local.namespace_name
    labels    = local.reviewer_labels
  }
  automount_service_account_token = false
}

resource "kubernetes_cluster_role_v1" "reviewer" {
  count = var.token_review_proxy_enabled ? 1 : 0
  metadata {
    name   = "${var.namespace}-${local.reviewer_name}"
    labels = local.reviewer_labels
  }
  rule {
    api_groups = ["authentication.k8s.io"]
    resources  = ["tokenreviews"]
    verbs      = ["create"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "reviewer" {
  count = var.token_review_proxy_enabled ? 1 : 0
  metadata {
    name   = "${var.namespace}-${local.reviewer_name}"
    labels = local.reviewer_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.reviewer[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.reviewer[0].metadata[0].name
    namespace = local.namespace_name
  }
}

resource "kubernetes_config_map_v1" "reviewer" {
  count = var.token_review_proxy_enabled ? 1 : 0
  metadata {
    name      = local.reviewer_name
    namespace = local.namespace_name
    labels    = local.reviewer_labels
  }
  data = { "reviewer.py" = file("${path.module}/reviewer.py") }
}

resource "kubectl_manifest" "reviewer_isolation" {
  count = var.token_review_proxy_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata   = { name = local.reviewer_name, namespace = local.namespace_name }
    spec = {
      endpointSelector  = { matchLabels = { "app.kubernetes.io/name" = local.reviewer_name, "migration-role" = "token-review-proxy" } }
      enableDefaultDeny = { ingress = true, egress = true }
      ingress = [{
        fromEndpoints = [
          { matchLabels = { "k8s:io.kubernetes.pod.namespace" = var.namespace, "migration-role" = "isolated-server", "app.kubernetes.io/name" = var.name } },
          { matchLabels = { "k8s:io.kubernetes.pod.namespace" = var.namespace, "migration-role" = "lab-client" } }
        ]
        toPorts = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
      }]
      egress = [{
        toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "kube-system", "k8s:k8s-app" = "kube-dns" } }]
        toPorts     = [{ ports = [{ port = "53", protocol = "UDP" }, { port = "53", protocol = "TCP" }], rules = { dns = [{ matchPattern = "*" }] } }]
        }, {
        toEntities = ["kube-apiserver"]
        toPorts    = [{ ports = [{ port = "443", protocol = "TCP" }, { port = "6443", protocol = "TCP" }] }]
      }]
    }
  })
}

resource "kubernetes_service_v1" "reviewer" {
  count = var.token_review_proxy_enabled ? 1 : 0
  metadata {
    name        = local.reviewer_name
    namespace   = local.namespace_name
    labels      = local.reviewer_labels
    annotations = { "external-dns.alpha.kubernetes.io/exclude" = "true" }
  }
  spec {
    type     = "ClusterIP"
    selector = local.reviewer_labels
    port {
      name        = "review"
      port        = 8080
      target_port = "review"
    }
  }
}

resource "kubernetes_deployment_v1" "reviewer" {
  count = var.token_review_proxy_enabled ? 1 : 0
  metadata {
    name      = local.reviewer_name
    namespace = local.namespace_name
    labels    = local.reviewer_labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = local.reviewer_labels }
    template {
      metadata {
        labels      = local.reviewer_labels
        annotations = { "linkerd.io/inject" = "disabled", "checksum/config" = sha256(file("${path.module}/reviewer.py")) }
      }
      spec {
        service_account_name            = kubernetes_service_account_v1.reviewer[0].metadata[0].name
        automount_service_account_token = false
        node_selector                   = var.node_selector
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          fs_group        = 65532
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name    = "reviewer"
          image   = var.token_review_proxy_image
          command = ["python", "/app/reviewer.py"]
          env {
            name  = "LAB_NAMESPACE"
            value = var.namespace
          }
          env {
            name  = "PYTHONDONTWRITEBYTECODE"
            value = "1"
          }
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }
          port {
            name           = "review"
            container_port = 8080
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = "review"
            }
          }
          volume_mount {
            name       = "script"
            mount_path = "/app"
            read_only  = true
          }
          volume_mount {
            name       = "identity"
            mount_path = "/identity"
            read_only  = true
          }
          volume_mount {
            name       = "authorization"
            mount_path = "/authorization"
            read_only  = true
          }
        }
        volume {
          name = "script"
          config_map { name = kubernetes_config_map_v1.reviewer[0].metadata[0].name }
        }
        volume {
          name = "identity"
          projected {
            default_mode = "0440"
            sources {
              service_account_token {
                expiration_seconds = 600
                path               = "token"
              }
            }
            sources {
              config_map {
                name = "kube-root-ca.crt"
                items {
                  key  = "ca.crt"
                  path = "ca.crt"
                }
              }
            }
          }
        }
        volume {
          name = "authorization"
          secret {
            secret_name  = coalesce(var.token_review_proxy_secret_name, "missing-authorization")
            default_mode = "0440"
            items {
              key  = "token"
              path = "token"
            }
          }
        }
      }
    }
  }
  lifecycle {
    precondition {
      condition     = var.token_review_proxy_secret_name != null
      error_message = "Create a protected dedicated lab authorization Secret before enabling the reviewer."
    }
  }
  depends_on = [kubernetes_cluster_role_binding_v1.reviewer, kubectl_manifest.reviewer_isolation]
}
