# cspell:ignore admissionregistration healthz logtostderr reinvocation selfsigned serviceaccount serviceaccounts
terraform {
  required_providers {
    kubectl    = { source = "alekc/kubectl", version = "2.1.6" }
    kubernetes = { source = "hashicorp/kubernetes", version = "2.35.0" }
    pf         = { source = "panfactum/pf", version = "0.0.7" }
  }
}

locals {
  namespace = var.create_namespace ? module.namespace[0].namespace : var.namespace
  # Upstream app name: the webhook exempts its own pods by this label so a full outage can self-heal.
  app_name = "amazon-eks-pod-identity-webhook"
  match_labels = {
    "app.kubernetes.io/name"     = local.app_name
    "app.kubernetes.io/instance" = var.name
  }
  replicas     = 2
  webhook_port = 8443
  # The CA outlives every leaf; cainjector publishes the CA, so leaf renewals never change the bundle.
  certificates = {
    ca      = { duration = "87600h", renew_before = "720h" }
    serving = { duration = "2160h", renew_before = "720h" }
  }
  metrics_port = 9999

  object_selector_expressions = concat(
    [
      { key = "eks.amazonaws.com/skip-pod-identity-webhook", operator = "DoesNotExist" },
      { key = "app.kubernetes.io/name", operator = "NotIn", values = [local.app_name] },
    ],
    [for e in var.bootstrap_exempt_selector_expressions : { for k, v in e : k => v if !(k == "values" && length(v) == 0) }]
  )

  probe = {
    httpGet          = { path = "/healthz", port = "https", scheme = "HTTPS" }
    periodSeconds    = 10
    timeoutSeconds   = 3
    successThreshold = 1
  }

  deployment = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = var.name
      namespace = local.namespace
      labels    = module.util.labels
    }
    spec = {
      # Fixed at 2 for every SLA level: failurePolicy is Fail, and a third replica cannot schedule
      # under required host anti-affinity whenever one of the three controllers is down.
      replicas = local.replicas
      # Required host anti-affinity leaves no node for a surge pod.
      strategy = { type = "RollingUpdate", rollingUpdate = { maxSurge = 0, maxUnavailable = 1 } }
      selector = { matchLabels = module.util.match_labels }
      template = {
        metadata = {
          labels      = module.util.labels
          annotations = { "linkerd.io/inject" = "disabled" }
        }
        spec = {
          serviceAccountName            = kubernetes_service_account_v1.webhook.metadata[0].name
          priorityClassName             = module.constants.cluster_important_priority_class_name
          affinity                      = module.util.affinity
          tolerations                   = module.util.tolerations
          topologySpreadConstraints     = module.util.topology_spread_constraints
          terminationGracePeriodSeconds = 30
          securityContext = {
            runAsNonRoot   = true
            runAsUser      = 65534
            runAsGroup     = 65534
            seccompProfile = { type = "RuntimeDefault" }
          }
          containers = [{
            name  = "webhook"
            image = var.image
            command = [
              "/webhook",
              "--in-cluster=false",
              "--namespace=${local.namespace}",
              "--service-name=${kubernetes_service_v1.webhook.metadata[0].name}",
              "--tls-cert=/etc/webhook/certs/tls.crt",
              "--tls-key=/etc/webhook/certs/tls.key",
              "--port=${local.webhook_port}",
              "--metrics-port=${local.metrics_port}",
              "--annotation-prefix=eks.amazonaws.com",
              "--token-audience=sts.amazonaws.com",
              "--token-expiration=${var.token_expiration_seconds}",
              "--token-mount-path=/var/run/secrets/eks.amazonaws.com/serviceaccount",
              "--aws-default-region=${var.region}",
              "--sts-regional-endpoint=true",
              "--service-account-lookup-grace-period=${var.service_account_lookup_grace_period}",
              "--logtostderr",
            ]
            ports = [
              { name = "https", containerPort = local.webhook_port, protocol = "TCP" },
              { name = "metrics", containerPort = local.metrics_port, protocol = "TCP" },
            ]
            readinessProbe = merge(local.probe, { failureThreshold = 3 })
            livenessProbe  = merge(local.probe, { failureThreshold = 6 })
            # Keeps serving while the endpoint removal reaches every API server.
            lifecycle = { preStop = { sleep = { seconds = 5 } } }
            resources = {
              requests = { cpu = "10m", memory = "49Mi" }
              limits   = { memory = "64Mi" }
            }
            securityContext = {
              allowPrivilegeEscalation = false
              readOnlyRootFilesystem   = true
              capabilities             = { drop = ["ALL"] }
            }
            volumeMounts = [{ name = "cert", mountPath = "/etc/webhook/certs", readOnly = true }]
          }]
          volumes = [{ name = "cert", secret = { secretName = module.serving_cert.secret_name } }]
        }
      }
    }
  }

  webhook_configuration = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "MutatingWebhookConfiguration"
    metadata = {
      name   = var.name
      labels = module.util.labels
      annotations = {
        # cainjector copies the serving Secret's ca.crt, which is the long-lived CA, so leaf renewals keep the bundle.
        "cert-manager.io/inject-ca-from" = "${local.namespace}/${module.serving_cert.certificate_name}"
      }
    }
    webhooks = [{
      name = "pod-identity-webhook.amazonaws.com"
      # v0.6.17 decodes and answers admission/v1beta1 only.
      admissionReviewVersions = ["v1beta1"]
      sideEffects             = "None"
      failurePolicy           = "Fail"
      matchPolicy             = "Equivalent"
      reinvocationPolicy      = "Never"
      timeoutSeconds          = 10
      namespaceSelector       = {}
      objectSelector          = { matchExpressions = local.object_selector_expressions }
      clientConfig = {
        service = {
          name      = kubernetes_service_v1.webhook.metadata[0].name
          namespace = local.namespace
          path      = "/mutate"
          port      = 443
        }
      }
      rules = [{
        operations  = ["CREATE"]
        apiGroups   = [""]
        apiVersions = ["v1"]
        resources   = ["pods"]
        scope       = "*"
      }]
    }]
  }
}

module "namespace" {
  count          = var.create_namespace ? 1 : 0
  source         = "../kube_namespace"
  namespace      = var.namespace
  linkerd_inject = false
}

module "constants" {
  source = "../kube_constants"
}

module "util" {
  source                      = "../kube_workload_utility"
  workload_name               = var.name
  match_labels                = local.match_labels
  controller_nodes_required   = true
  host_anti_affinity_required = true
  az_spread_preferred         = true
  linkerd_required            = false
  pull_through_cache_enabled  = false
  # Talos controllers are control-plane nodes; tolerate the taint if it is ever enabled.
  extra_tolerations = [{ key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" }]
}

resource "kubernetes_service_account_v1" "webhook" {
  metadata {
    name      = var.name
    namespace = local.namespace
    labels    = module.util.labels
  }
}

resource "kubernetes_cluster_role_v1" "webhook" {
  metadata {
    name   = var.name
    labels = module.util.labels
  }
  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "webhook" {
  metadata {
    name   = var.name
    labels = module.util.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.webhook.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.webhook.metadata[0].name
    namespace = local.namespace
  }
}

/***************************************
* Certificates
* A namespaced CA avoids the Vault-backed ClusterIssuers, which need IRSA and therefore this webhook.
***************************************/

resource "kubectl_manifest" "selfsigned_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata   = { name = "${var.name}-selfsigned", namespace = local.namespace, labels = module.util.labels }
    spec       = { selfSigned = {} }
  })
  server_side_apply = true
  force_conflicts   = true
}

module "ca_cert" {
  source             = "../kube_internal_cert"
  namespace          = local.namespace
  secret_name        = "${var.name}-ca"
  common_name        = "${var.name}-ca"
  sans_enabled       = false
  is_ca              = true
  issuer_name        = "${var.name}-selfsigned"
  use_cluster_issuer = false
  duration           = local.certificates.ca.duration
  renew_before       = local.certificates.ca.renew_before
  # Keeping the CA key on renewal lets leaves signed by the old CA certificate still verify.
  private_key_rotation_enabled = false
  depends_on                   = [kubectl_manifest.selfsigned_issuer]
}

resource "kubectl_manifest" "ca_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata   = { name = "${var.name}-ca", namespace = local.namespace, labels = module.util.labels }
    spec       = { ca = { secretName = module.ca_cert.secret_name } }
  })
  server_side_apply = true
  force_conflicts   = true
}

module "serving_cert" {
  source             = "../kube_internal_cert"
  namespace          = local.namespace
  secret_name        = "${var.name}-tls"
  service_names      = [var.name]
  issuer_name        = "${var.name}-ca"
  use_cluster_issuer = false
  duration           = local.certificates.serving.duration
  renew_before       = local.certificates.serving.renew_before
  depends_on         = [kubectl_manifest.ca_issuer]
}

/***************************************
* Workload
***************************************/

resource "kubernetes_service_v1" "webhook" {
  metadata {
    name      = var.name
    namespace = local.namespace
    labels    = module.util.labels
  }
  spec {
    type     = "ClusterIP"
    selector = module.util.match_labels
    port {
      name         = "https"
      port         = 443
      target_port  = "https"
      app_protocol = "https"
    }
    port {
      name         = "metrics"
      port         = local.metrics_port
      target_port  = "metrics"
      app_protocol = "http"
    }
  }
}

# kubectl_manifest instead of kubernetes_deployment_v1: provider 2.35.0 has no preStop sleep handler,
# and the image has no shell for an exec sleep.
resource "kubectl_manifest" "deployment" {
  yaml_body         = yamlencode(local.deployment)
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true
  depends_on        = [kubernetes_cluster_role_binding_v1.webhook]
}

resource "kubectl_manifest" "pdb" {
  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata   = { name = var.name, namespace = local.namespace, labels = module.util.labels }
    spec = {
      unhealthyPodEvictionPolicy = "AlwaysAllow"
      selector                   = { matchLabels = module.util.match_labels }
      maxUnavailable             = 1
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.deployment]
}

resource "kubectl_manifest" "webhook" {
  count     = var.mutating_webhook_enabled ? 1 : 0
  yaml_body = yamlencode(local.webhook_configuration)
  # Server-side apply leaves the cainjector-owned caBundle out of the diff.
  server_side_apply = true
  force_conflicts   = true
  wait_for {
    field {
      key        = "webhooks.[0].clientConfig.caBundle"
      value      = "^.+$"
      value_type = "regex"
    }
  }
  depends_on = [kubectl_manifest.deployment, kubernetes_service_v1.webhook, module.serving_cert, module.ca_cert]
}
