terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.35.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.1.6"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  namespace_name = var.create_namespace ? kubernetes_namespace_v1.lab[0].metadata[0].name : var.namespace
  labels = {
    "app.kubernetes.io/name"                   = var.name
    "app.kubernetes.io/part-of"                = "vault-migration-lab"
    "panfactum.com/pull-through-cache-enabled" = "false"
    "migration-role"                           = "isolated-server"
  }
  aws_hosts = [
    "kms.${data.aws_region.current.name}.${data.aws_partition.current.dns_suffix}",
    "sts.${data.aws_region.current.name}.${data.aws_partition.current.dns_suffix}"
  ]
  # No IAM, database, S3, Kubernetes API or wildcard actions. A copied lease
  # manager must not acquire its production AWS permissions from this identity.
  iam_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ExistingSealKeyOnly"
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = [var.seal_key_arn]
    }]
  }
  network_policy = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata   = { name = "${var.name}-isolation", namespace = var.namespace }
    spec = {
      endpointSelector = { matchLabels = {
        "migration-role"         = "isolated-server"
        "app.kubernetes.io/name" = var.name
      } }
      enableDefaultDeny = { ingress = true, egress = true }
      ingress = [{
        fromEndpoints = [{ matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = var.namespace
          "migration-role"                  = "lab-client"
        } }]
        toPorts = [{ ports = [{ port = "8200", protocol = "TCP" }] }]
      }]
      egress = concat([{
        toEndpoints = [{ matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = "kube-system"
          "k8s:k8s-app"                     = "kube-dns"
        } }]
        toPorts = [{
          ports = [{ port = "53", protocol = "UDP" }, { port = "53", protocol = "TCP" }]
          rules = { dns = [{ matchPattern = "*" }] }
        }]
        }], [for host in local.aws_hosts : {
        toFQDNs = [{ matchName = host }]
        toPorts = [{ ports = [{ port = "443", protocol = "TCP" }], serverNames = [host] }]
        }], var.token_review_proxy_enabled ? [{
        toEndpoints = [{ matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = var.namespace
          "migration-role"                  = "token-review-proxy"
          "app.kubernetes.io/name"          = local.reviewer_name
        } }]
        toPorts = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
      }] : [])
    }
  }
  configuration = templatefile("${path.module}/server.hcl.tftpl", {
    engine       = var.engine
    plugins      = var.plugins
    region       = data.aws_region.current.name
    seal_key_arn = var.seal_key_arn
    role_arn     = module.aws_auth.role_arn
    node_id      = var.name
    namespace    = var.namespace
  })
}

module "aws_auth" {
  source                    = "../kube_sa_auth_aws"
  service_account           = var.name
  service_account_namespace = var.namespace
  iam_policy_json           = jsonencode(local.iam_policy)
  annotate_service_account  = false
  oidc_provider_arn         = var.oidc_provider_arn
  oidc_issuer_url           = var.oidc_issuer_url
  ip_restrictions_enabled   = false
  cluster_subnet_ids        = []
}

resource "kubernetes_namespace_v1" "lab" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of"                = "vault-migration-lab"
      "panfactum.com/pull-through-cache-enabled" = "false"
      "pod-security.kubernetes.io/enforce"       = "restricted"
    }
    annotations = { "linkerd.io/inject" = "disabled" }
  }
}

resource "kubernetes_resource_quota_v1" "lab" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name      = "migration-lab-budget"
    namespace = local.namespace_name
  }
  spec {
    hard = {
      "requests.memory"        = "${var.memory_request_quota_mi}Mi"
      "requests.cpu"           = "500m"
      "limits.memory"          = "1536Mi"
      "requests.storage"       = "4Gi"
      "persistentvolumeclaims" = "4"
      "pods"                   = "6"
    }
  }
}

resource "kubernetes_service_account_v1" "lab" {
  metadata {
    name      = var.name
    namespace = local.namespace_name
    labels    = local.labels
  }
  automount_service_account_token = false
}

resource "kubernetes_persistent_volume_claim_v1" "lab" {
  metadata {
    name      = "${var.name}-data"
    namespace = local.namespace_name
    labels    = local.labels
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources { requests = { storage = var.storage_size } }
  }
  # WaitForFirstConsumer must not deadlock installation with replicas=0.
  wait_until_bound = false
}

resource "kubectl_manifest" "isolation" {
  yaml_body         = yamlencode(local.network_policy)
  server_side_apply = true
  wait_for_rollout  = false
  depends_on        = [kubernetes_namespace_v1.lab]
}

resource "kubernetes_config_map_v1" "server" {
  metadata {
    name      = "${var.name}-config"
    namespace = local.namespace_name
    labels    = local.labels
  }
  data = { "server.hcl" = local.configuration }
}

resource "kubernetes_service_v1" "server" {
  metadata {
    name        = var.name
    namespace   = local.namespace_name
    labels      = local.labels
    annotations = { "external-dns.alpha.kubernetes.io/exclude" = "true" }
  }
  spec {
    type                        = "ClusterIP"
    selector                    = { "app.kubernetes.io/name" = var.name }
    publish_not_ready_addresses = true
    port {
      name        = "api"
      port        = 8200
      target_port = "api"
    }
  }
}

resource "kubernetes_stateful_set_v1" "server" {
  metadata {
    name      = var.name
    namespace = local.namespace_name
    labels    = local.labels
  }
  wait_for_rollout = false
  spec {
    service_name = kubernetes_service_v1.server.metadata[0].name
    replicas     = var.server_enabled ? 1 : 0
    selector { match_labels = { "app.kubernetes.io/name" = var.name } }
    update_strategy { type = "OnDelete" }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "linkerd.io/inject" = "disabled"
          "checksum/config"   = sha256(local.configuration)
        }
      }
      spec {
        service_account_name             = kubernetes_service_account_v1.lab.metadata[0].name
        automount_service_account_token  = false
        node_selector                    = var.node_selector
        termination_grace_period_seconds = 20
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name    = "server"
          image   = var.image
          command = [var.engine == "openbao" ? "bao" : "vault"]
          args    = ["server", "-config=/config/server.hcl"]
          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
          dynamic "env" {
            for_each = {
              AWS_ROLE_ARN                = module.aws_auth.role_arn
              AWS_WEB_IDENTITY_TOKEN_FILE = "/identity/token"
              AWS_REGION                  = data.aws_region.current.name
              AWS_DEFAULT_REGION          = data.aws_region.current.name
              AWS_EC2_METADATA_DISABLED   = "true"
              AWS_STS_REGIONAL_ENDPOINTS  = "regional"
              VAULT_ADDR                  = "http://127.0.0.1:8200"
              BAO_ADDR                    = "http://127.0.0.1:8200"
              TMPDIR                      = "/tmp"
            }
            content {
              name  = env.key
              value = env.value
            }
          }
          port {
            name           = "api"
            container_port = 8200
          }
          startup_probe {
            http_get {
              path = "/v1/sys/seal-status"
              port = "api"
            }
            period_seconds    = 2
            failure_threshold = 60
          }
          readiness_probe {
            http_get {
              path = "/v1/sys/health?standbyok=true"
              port = "api"
            }
            period_seconds = 5
          }
          volume_mount {
            name       = "configuration"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "identity"
            mount_path = "/identity"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/vault/data"
          }
          volume_mount {
            name       = "temporary"
            mount_path = "/tmp"
          }
        }
        volume {
          name = "configuration"
          config_map { name = kubernetes_config_map_v1.server.metadata[0].name }
        }
        volume {
          name = "identity"
          projected {
            default_mode = "0440"
            sources {
              service_account_token {
                audience           = "sts.amazonaws.com"
                expiration_seconds = 3600
                path               = "token"
              }
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.lab.metadata[0].name }
        }
        volume {
          name = "temporary"
          empty_dir { size_limit = "32Mi" }
        }
      }
    }
  }
  lifecycle {
    precondition {
      condition     = !var.server_enabled || var.isolation_verified
      error_message = "Verify current effective network and IAM isolation before enabling the lab server."
    }
    precondition {
      condition = var.engine != "openbao" || (
        anytrue([for p in var.plugins : p.type == "kms" && p.name == "awskms"]) &&
        anytrue([for p in var.plugins : p.type == "secret" && p.name == "aws"])
      )
      error_message = "The OpenBao clone requires preinstalled declared awskms and AWS secrets plugins before startup."
    }
  }
  depends_on = [kubectl_manifest.isolation, module.aws_auth, kubernetes_resource_quota_v1.lab]
}
