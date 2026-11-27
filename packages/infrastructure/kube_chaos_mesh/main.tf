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
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }
  }
}

resource "kubernetes_namespace_v1" "main" {
  metadata {
    name = "chaos-mesh"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
    annotations = {
      "linkerd.io/inject" = "disabled"
    }
  }
}

resource "helm_release" "main" {
  name            = "chaos-mesh"
  namespace       = kubernetes_namespace_v1.main.metadata[0].name
  repository      = "https://charts.chaos-mesh.org"
  chart           = "chaos-mesh"
  version         = var.helm_version
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600
  max_history     = 5

  values = [yamlencode({
    customLabels    = { "panfactum.com/pull-through-cache-enabled" = "false" }
    enableProfiling = false
    controllerManager = {
      replicaCount            = 1
      enableFilterNamespace   = true
      allowHostNetworkTesting = false
      podAnnotations          = { "linkerd.io/inject" = "disabled" }
      resources = {
        requests = { cpu = "25m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    chaosDaemon = {
      runtime        = "containerd"
      socketPath     = var.container_runtime_socket
      tolerations    = [{ operator = "Exists" }]
      podAnnotations = { "linkerd.io/inject" = "disabled" }
      resources = {
        requests = { cpu = "25m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    dashboard = {
      create         = true
      securityMode   = true
      service        = { type = "ClusterIP" }
      podAnnotations = { "linkerd.io/inject" = "disabled" }
    }
    dnsServer  = { create = false }
    prometheus = { create = false }
    bpfki      = { create = false }
  })]
}
