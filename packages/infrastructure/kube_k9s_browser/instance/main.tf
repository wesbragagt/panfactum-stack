terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "3.0.1"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  name   = "k9s"
  labels = merge(data.pf_kube_labels.labels.labels, { app = local.name })
  config = {
    "setup.sh"              = file("${path.module}/../setup.sh")
    "views.yaml"            = file("${path.module}/../views.yaml")
    "catppuccin-mocha.yaml" = file("${path.module}/../skins/catppuccin-mocha.yaml")
  }
  # Catppuccin Mocha for xterm.js; the browser renders the first fontFamily installed on the viewer's machine.
  # ttyd JSON-parses each value, so a font list must be a JSON string or it stops at the first name.
  ttyd_options = {
    fontSize   = "15"
    fontFamily = jsonencode("JetBrainsMono Nerd Font Mono, JetBrains Mono, Menlo, Consolas, DejaVu Sans Mono, monospace")
    theme = jsonencode({
      background  = "#1e1e2e", foreground = "#cdd6f4", cursor = "#f5e0dc", selectionBackground = "#585b70",
      black       = "#45475a", red = "#f38ba8", green = "#a6e3a1", yellow = "#f9e2af",
      blue        = "#89b4fa", magenta = "#f5c2e7", cyan = "#94e2d5", white = "#bac2de",
      brightBlack = "#585b70", brightRed = "#f38ba8", brightGreen = "#a6e3a1", brightYellow = "#f9e2af",
      brightBlue  = "#89b4fa", brightMagenta = "#f5c2e7", brightCyan = "#94e2d5", brightWhite = "#a6adc8",
    })
  }
  container_security_context = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    capabilities             = { drop = ["ALL"] }
  }
}

data "pf_kube_labels" "labels" {
  module = "kube_k9s_browser"
}

resource "kubernetes_namespace_v1" "k9s" {
  metadata {
    name   = var.namespace
    labels = data.pf_kube_labels.labels.labels
  }
}

/***************************************
* RBAC
***************************************/

resource "kubernetes_service_account_v1" "k9s" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.k9s.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_binding_v1" "k9s" {
  metadata {
    name   = "k9s-${var.namespace}"
    labels = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = var.read_only ? "view" : "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.k9s.metadata[0].name
    namespace = var.namespace
  }
}

// The built-in view role covers namespaced resources only; k9s also needs nodes.
resource "kubernetes_cluster_role_v1" "nodes" {
  count = var.read_only ? 1 : 0
  metadata {
    name   = "k9s-${var.namespace}-nodes"
    labels = local.labels
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "nodes" {
  count = var.read_only ? 1 : 0
  metadata {
    name   = "k9s-${var.namespace}-nodes"
    labels = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.nodes[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.k9s.metadata[0].name
    namespace = var.namespace
  }
}

/***************************************
* ttyd + k9s
***************************************/

resource "kubernetes_config_map_v1" "k9s" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.k9s.metadata[0].name
    labels    = local.labels
  }
  data = local.config
}

resource "kubectl_manifest" "deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = local.name, namespace = var.namespace, labels = local.labels }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = local.name } }
      template = {
        metadata = {
          labels      = local.labels
          annotations = { "checksum/config" = sha256(jsonencode(local.config)) }
        }
        spec = {
          serviceAccountName = kubernetes_service_account_v1.k9s.metadata[0].name
          nodeSelector       = var.node_selector
          tolerations        = var.tolerations
          securityContext = {
            runAsNonRoot   = true
            runAsUser      = 10001
            runAsGroup     = 10001
            fsGroup        = 10001
            seccompProfile = { type = "RuntimeDefault" }
          }
          initContainers = [{
            name            = "tools"
            image           = "alpine:3.22"
            command         = ["sh", "/config/setup.sh"]
            env             = [{ name = "CONTEXT_NAME", value = var.context_name }]
            volumeMounts    = [{ name = "tools", mountPath = "/tools" }, { name = "config", mountPath = "/config" }]
            securityContext = local.container_security_context
            resources       = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "128Mi" } }
          }]
          containers = [{
            name = "ttyd"
            # Every browser tab gets its own k9s process.
            image = "alpine:3.22"
            command = concat(
              ["/tools/ttyd", "-W", "-p", "7681", "-t", "titleFixed=k9s ${var.context_name}"],
              flatten([for k, v in local.ttyd_options : ["-t", "${k}=${v}"]]),
              ["/tools/k9s"], var.read_only ? ["--readonly"] : [],
            )
            env = [
              { name = "HOME", value = "/tmp" },
              { name = "PATH", value = "/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
              # k9s is built without cgo and resolves the user from $USER.
              { name = "USER", value = "k9s" },
              { name = "KUBECONFIG", value = "/tools/kubeconfig" },
              { name = "TERM", value = "xterm-256color" },
              { name = "KUBE_EDITOR", value = "/tools/vim" },
              { name = "EDITOR", value = "/tools/vim" },
              { name = "K9S_SKIN", value = "catppuccin-mocha" },
            ]
            ports          = [{ name = "http", containerPort = 7681 }]
            readinessProbe = { tcpSocket = { port = "http" }, periodSeconds = 10 }
            livenessProbe  = { tcpSocket = { port = "http" }, periodSeconds = 20 }
            volumeMounts = [
              { name = "tools", mountPath = "/tools", readOnly = true },
              { name = "tmp", mountPath = "/tmp" },
              # subPath leaves the rest of the k9s config dir writable.
              { name = "config", mountPath = "/tmp/.config/k9s/views.yaml", subPath = "views.yaml", readOnly = true },
              { name = "config", mountPath = "/tmp/.config/k9s/skins/catppuccin-mocha.yaml", subPath = "catppuccin-mocha.yaml", readOnly = true },
            ]
            securityContext = local.container_security_context
            resources       = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = "512Mi" } }
          }]
          volumes = [
            { name = "tools", emptyDir = {} },
            { name = "tmp", emptyDir = {} },
            { name = "config", configMap = { name = kubernetes_config_map_v1.k9s.metadata[0].name } },
          ]
        }
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
}

resource "kubernetes_service_v1" "k9s" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.k9s.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = { app = local.name }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

/***************************************
* Vault login
***************************************/

module "vault_proxy" {
  source = "../../kube_vault_proxy"

  namespace           = kubernetes_namespace_v1.k9s.metadata[0].name
  domain              = var.domain
  vault_domain        = var.vault_domain
  allowed_vault_roles = var.allowed_vault_roles
  gateway_api = {
    parent_name      = var.gateway_api.parent_name
    parent_namespace = var.gateway_api.parent_namespace
    upstream_url     = "http://${local.name}.${var.namespace}.svc.cluster.local"
  }

  controller_nodes_enabled             = var.controller_nodes_enabled
  instance_type_anti_affinity_required = var.instance_type_anti_affinity_required
  panfactum_scheduler_enabled          = var.panfactum_scheduler_enabled
  pull_through_cache_enabled           = var.pull_through_cache_enabled
  vpa_enabled                          = var.vpa_enabled

  # Required host anti-affinity means a rollout's surge pod often waits for a new
  # Karpenter node, which took 61s and 90s to become Ready on 2026-11-20.
  helm_timeout_seconds = 300
}
