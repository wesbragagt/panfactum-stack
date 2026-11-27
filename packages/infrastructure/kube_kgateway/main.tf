# HTTPS uses a cert-manager Secret, with an optional NLB owned by the AWS Load Balancer Controller.
# Setting local_http_port serves plain HTTP from a ClusterIP Service.
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "3.0.1"
    }
  }
}

locals {
  local_mode = var.local_http_port != null
}

# Deleting a CRD deletes every Gateway and route, so destroy forgets CRDs instead of deleting them.
resource "kubectl_manifest" "crds" {
  for_each          = fileset(path.module, "manifests/*.yaml")
  yaml_body         = file("${path.module}/${each.key}")
  apply_only        = true
  server_side_apply = true
  # The client engine reports false drift on int64 schema maximums the apiserver stores as rounded floats.
  drift_engine = var.crd_drift_engine
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_namespace_v1" "kgateway" {
  metadata {
    name        = var.namespace
    annotations = { "linkerd.io/inject" = "disabled" }
  }
}

resource "helm_release" "kgateway" {
  namespace  = kubernetes_namespace_v1.kgateway.metadata[0].name
  name       = "kgateway"
  chart      = "${path.module}/kgateway-v2.5.1.tgz"
  wait       = true
  timeout    = 300
  depends_on = [kubectl_manifest.crds]
  values = [yamlencode({
    fullnameOverride = "kgateway"
    image            = { registry = "ghcr.io/kgateway-dev" }
    controller = {
      replicaCount = var.controller_replicas
      strategy     = var.controller_replicas > 1 ? { type = "RollingUpdate" } : { type = "Recreate" }
      affinity = var.controller_replicas > 1 ? { podAntiAffinity = { requiredDuringSchedulingIgnoredDuringExecution = [{
        labelSelector = { matchLabels = { "app.kubernetes.io/instance" = "kgateway", "app.kubernetes.io/name" = "kgateway" } }
        topologyKey   = "kubernetes.io/hostname"
      }] } } : {}
      nodeSelector   = var.node_selector
      tolerations    = var.tolerations
      podAnnotations = { "linkerd.io/inject" = "disabled" }
      image = {
        registry   = "ghcr.io/kgateway-dev"
        repository = "kgateway"
        tag        = "v2.5.1@sha256:0e9500f820b8f686d7cac5d599918a43b4237f625bbbfd7d0107e50182b05a03"
      }
      resources = {
        requests = { cpu = "50m", memory = "256Mi" }
        limits   = { memory = "256Mi" }
      }
      service = { type = "ClusterIP" }
    }
  })]
}

resource "kubectl_manifest" "gateway_parameters" {
  yaml_body = yamlencode({
    apiVersion = "gateway.kgateway.dev/v1alpha1"
    kind       = "GatewayParameters"
    metadata   = { name = var.gateway_name, namespace = var.namespace }
    spec = {
      kube = {
        service = [{ type = "ClusterIP" }, {
          type = "LoadBalancer"
          extraAnnotations = {
            # "external" makes the AWS LB Controller own the NLB; the CCM runs only cloud-node.
            "service.beta.kubernetes.io/aws-load-balancer-type"   = "external"
            "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
            # Cilium ENI IPAM gives pods VPC IPs, so the NLB targets pods directly.
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
            # Explicit subnets: the shared PUBLIC subnet role tags belong to main state.
            "service.beta.kubernetes.io/aws-load-balancer-subnets" = join(",", var.public_subnet_ids)
            "service.beta.kubernetes.io/aws-load-balancer-name"    = var.load_balancer_name
            "external-dns.alpha.kubernetes.io/hostname"            = join(",", var.dns_hostnames)
          }
        }][var.enable_public_load_balancer && !local.local_mode ? 1 : 0]
        deployment = { replicas = var.proxy_replicas }
        podTemplate = {
          extraAnnotations = { "linkerd.io/inject" = "disabled" }
          nodeSelector     = var.node_selector
          tolerations      = var.tolerations
          topologySpreadConstraints = [{
            maxSkew           = 1
            topologyKey       = "kubernetes.io/hostname"
            whenUnsatisfiable = "ScheduleAnyway"
            labelSelector     = { matchLabels = { "gateway.networking.k8s.io/gateway-name" = var.gateway_name } }
          }]
        }
        envoyContainer = {
          image = {
            registry   = "ghcr.io/kgateway-dev"
            repository = "envoy-wrapper"
            tag        = "v2.5.1"
            digest     = "sha256:259ee9b7c3c36a8978b5f095b9d4b8f7cccb0a6f7af12df960fffa8900a4f186"
          }
          resources = {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
        }
      }
    }
  })
  server_side_apply = true
  depends_on        = [helm_release.kgateway]
}

resource "kubectl_manifest" "gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata   = { name = var.gateway_name, namespace = var.namespace }
    spec = {
      gatewayClassName = "kgateway"
      infrastructure = {
        parametersRef = { group = "gateway.kgateway.dev", kind = "GatewayParameters", name = var.gateway_name }
      }
      listeners = [[{
        name          = "http"
        protocol      = "HTTP"
        port          = var.local_http_port
        hostname      = "*.${var.domain}"
        allowedRoutes = { namespaces = { from = "All" } }
        }], [{
        name     = "https"
        protocol = "HTTPS"
        port     = 443
        hostname = "*.${var.domain}"
        tls = {
          mode            = "Terminate"
          certificateRefs = [{ name = var.tls_secret_name, namespace = var.tls_secret_namespace }]
        }
        allowedRoutes = { namespaces = { from = "All" } }
      }]][local.local_mode ? 0 : 1]
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.gateway_parameters, kubectl_manifest.reference_grant]
  lifecycle {
    precondition {
      condition     = local.local_mode || length(var.local_routes) == 0
      error_message = "local_routes requires local_http_port."
    }
  }
}

resource "kubectl_manifest" "reference_grant" {
  count = local.local_mode ? 0 : 1
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata   = { name = "kgateway-${var.gateway_name}-tls", namespace = var.tls_secret_namespace }
    spec = {
      from = [{ group = "gateway.networking.k8s.io", kind = "Gateway", namespace = var.namespace }]
      to   = [{ group = "", kind = "Secret", name = var.tls_secret_name }]
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.crds]
}

# Envoy rejects Upgrade requests with 403 unless enabled; Authentik's UI uses websockets.
resource "kubectl_manifest" "listener_policy" {
  yaml_body = yamlencode({
    apiVersion = "gateway.kgateway.dev/v1alpha1"
    kind       = "ListenerPolicy"
    metadata   = { name = var.gateway_name, namespace = var.namespace }
    spec = {
      targetRefs = [{ group = "gateway.networking.k8s.io", kind = "Gateway", name = var.gateway_name }]
      default    = { httpSettings = { upgradeConfig = { enabledUpgrades = ["websocket"] } } }
    }
  })
  server_side_apply = true
  depends_on        = [helm_release.kgateway]
}

moved {
  from = kubectl_manifest.reference_grant
  to   = kubectl_manifest.reference_grant[0]
}

# Local mode only: the gateway owner also owns the routes for the instance origins.
resource "kubectl_manifest" "local_route" {
  for_each = local.local_mode ? var.local_routes : {}
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = each.key, namespace = each.value.namespace }
    spec = {
      parentRefs = [{ name = var.gateway_name, namespace = var.namespace, sectionName = "http" }]
      hostnames  = [each.value.hostname]
      rules      = [{ backendRefs = [{ name = each.value.service, port = each.value.port }] }]
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.gateway]
}
