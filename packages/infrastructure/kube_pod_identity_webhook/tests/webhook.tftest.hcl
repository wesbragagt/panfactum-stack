# cspell:ignore cutover healthz serviceaccounts
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "pf" {
  mock_data "pf_kube_labels" {
    defaults = { labels = {} }
  }
}

variables {
  region = "us-east-2"
}

run "ha_topology" {
  command = plan
  assert {
    condition     = local.deployment.spec.replicas == 2
    error_message = "Two replicas must run at every SLA level because failurePolicy is Fail."
  }
  assert {
    condition = anytrue([for t in local.deployment.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution :
    t.topologyKey == "kubernetes.io/hostname" && jsonencode(t.labelSelector.matchLabels) == jsonencode(local.match_labels)])
    error_message = "Replicas must require distinct hosts."
  }
  assert {
    condition = anytrue([for c in local.deployment.spec.template.spec.topologySpreadConstraints :
    c.topologyKey == "topology.kubernetes.io/zone" && c.whenUnsatisfiable == "ScheduleAnyway"])
    error_message = "Replicas must prefer distinct zones without blocking scheduling."
  }
  assert {
    condition = anytrue([for e in local.deployment.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions :
    e.key == "panfactum.com/class" && e.operator == "In" && e.values == ["controller"]])
    error_message = "Replicas must run on controller nodes only."
  }
  assert {
    condition = anytrue([for t in local.deployment.spec.template.spec.tolerations :
    t.key == "node-role.kubernetes.io/control-plane" && t.operator == "Exists" && t.effect == "NoSchedule"])
    error_message = "Replicas must tolerate the control-plane taint."
  }
  assert {
    condition     = local.deployment.spec.template.spec.priorityClassName == "cluster-important"
    error_message = "The webhook must use the cluster-important priority class."
  }
  assert {
    condition     = local.deployment.spec.strategy.rollingUpdate.maxSurge == 0 && local.deployment.spec.strategy.rollingUpdate.maxUnavailable == 1
    error_message = "Rollouts must replace one pod at a time without surging."
  }
  assert {
    condition = (
      local.deployment.spec.template.spec.containers[0].lifecycle.preStop.sleep.seconds == 5 &&
      local.deployment.spec.template.spec.terminationGracePeriodSeconds == 30
    )
    error_message = "Terminating pods must keep serving while endpoints drain."
  }
  assert {
    condition = (
      local.deployment.spec.template.spec.containers[0].livenessProbe.failureThreshold == 6 &&
      local.deployment.spec.template.spec.containers[0].livenessProbe.timeoutSeconds == 3 &&
      local.deployment.spec.template.spec.containers[0].readinessProbe.httpGet.path == "/healthz"
    )
    error_message = "Probes must use /healthz with a 3s timeout and a liveness threshold of 6."
  }
  assert {
    condition     = local.deployment.spec.template.metadata.labels["panfactum.com/pull-through-cache-enabled"] == "false"
    error_message = "The webhook must not depend on the pull-through cache."
  }
  assert {
    condition     = local.deployment.spec.template.metadata.annotations["linkerd.io/inject"] == "disabled"
    error_message = "The webhook must not run a mesh sidecar."
  }
}

run "pdb" {
  command = plan
  assert {
    condition = (
      yamldecode(kubectl_manifest.pdb.yaml_body).spec.maxUnavailable == 1 &&
      yamldecode(kubectl_manifest.pdb.yaml_body).spec.unhealthyPodEvictionPolicy == "AlwaysAllow" &&
      jsonencode(yamldecode(kubectl_manifest.pdb.yaml_body).spec.selector.matchLabels) == jsonencode(local.match_labels)
    )
    error_message = "The PDB must allow one voluntary disruption and always evict unhealthy pods."
  }
}

run "container" {
  command = plan
  assert {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", local.deployment.spec.template.spec.containers[0].image))
    error_message = "The image must be pinned by digest."
  }
  assert {
    condition     = contains(local.deployment.spec.template.spec.containers[0].command, "--service-account-lookup-grace-period=2s")
    error_message = "A fresh replica must fall back to an API lookup for uncached ServiceAccounts."
  }
  assert {
    condition = alltrue([for a in [
      "--in-cluster=false",
      "--annotation-prefix=eks.amazonaws.com",
      "--token-audience=sts.amazonaws.com",
      "--token-expiration=86400",
      "--aws-default-region=us-east-2",
      "--namespace=kube-system",
      "--service-name=pod-identity-webhook",
      "--port=8443",
    ] : contains(local.deployment.spec.template.spec.containers[0].command, a)])
    error_message = "Container args must match the upstream out-of-cluster contract."
  }
  assert {
    condition = (
      local.deployment.spec.template.spec.containers[0].resources.requests.memory == "49Mi" &&
      local.deployment.spec.template.spec.containers[0].resources.limits.memory == "64Mi"
    )
    error_message = "Memory must be requested at 49Mi and limited to 64Mi."
  }
  assert {
    condition = (
      length(kubernetes_cluster_role_v1.webhook.rule) == 1 &&
      jsonencode(kubernetes_cluster_role_v1.webhook.rule[0].resources) == jsonencode(["serviceaccounts"]) &&
      toset(kubernetes_cluster_role_v1.webhook.rule[0].verbs) == toset(["get", "list", "watch"])
    )
    error_message = "RBAC must be limited to reading ServiceAccounts."
  }
  assert {
    condition = (
      kubernetes_service_v1.webhook.spec[0].type == "ClusterIP" &&
      kubernetes_service_v1.webhook.spec[0].internal_traffic_policy != "Local"
    )
    error_message = "The Service must be a plain ClusterIP Service."
  }
}

run "webhook_configuration" {
  command = plan
  assert {
    condition = (
      local.webhook_configuration.webhooks[0].failurePolicy == "Fail" &&
      local.webhook_configuration.webhooks[0].rules[0].operations == ["CREATE"] &&
      local.webhook_configuration.webhooks[0].rules[0].resources == ["pods"] &&
      local.webhook_configuration.webhooks[0].clientConfig.service.path == "/mutate" &&
      local.webhook_configuration.webhooks[0].clientConfig.service.port == 443
    )
    error_message = "The webhook must fail closed on pod CREATE at /mutate."
  }
  assert {
    condition     = local.webhook_configuration.metadata.annotations["cert-manager.io/inject-ca-from"] == "kube-system/pod-identity-webhook-tls"
    error_message = "cainjector must inject the CA from the serving certificate."
  }
  assert {
    condition     = yamldecode(kubectl_manifest.webhook[0].yaml_body).metadata.name == "pod-identity-webhook"
    error_message = "The webhook configuration must not reuse the Helm release name."
  }
  assert {
    condition = alltrue([for e in [
      { key = "eks.amazonaws.com/skip-pod-identity-webhook", operator = "DoesNotExist" },
      { key = "app.kubernetes.io/name", operator = "NotIn", values = ["amazon-eks-pod-identity-webhook"] },
      { key = "k8s-app", operator = "NotIn", values = ["cilium", "cilium-envoy", "kube-dns"] },
      { key = "io.cilium/app", operator = "NotIn", values = ["operator"] },
    ] : contains([for x in local.webhook_configuration.webhooks[0].objectSelector.matchExpressions : jsonencode(x)], jsonencode(e))])
    error_message = "The objectSelector must exempt the skip label, the webhook itself and Cilium/DNS."
  }
  assert {
    condition     = local.deployment.spec.template.metadata.labels["app.kubernetes.io/name"] == "amazon-eks-pod-identity-webhook"
    error_message = "The webhook's own pods must carry the self-exemption label."
  }
  assert {
    condition = !anytrue([for e in local.webhook_configuration.webhooks[0].objectSelector.matchExpressions :
    contains(try(e.values, []), "aws-cloud-controller-manager")])
    error_message = "aws-cloud-controller-manager uses IRSA and must not be exempted."
  }
}

run "certificates" {
  command = plan
  assert {
    condition = (
      local.certificates.ca.duration == "87600h" &&
      local.certificates.serving.duration == "2160h" &&
      local.certificates.serving.renew_before == "720h"
    )
    error_message = "The CA must last 10 years and the serving certificate 90 days, renewed 30 days early."
  }
}

run "webhook_disabled_for_cutover" {
  command = plan
  variables {
    mutating_webhook_enabled = false
  }
  assert {
    condition     = length(kubectl_manifest.webhook) == 0
    error_message = "Cutover mode must not create a webhook configuration."
  }
  assert {
    condition     = local.deployment.spec.replicas == 2 && kubectl_manifest.pdb.yaml_body != null
    error_message = "Cutover mode must still create the Deployment and PDB."
  }
}

run "custom_namespace" {
  command = plan
  variables {
    namespace        = "pod-identity"
    create_namespace = true
  }
  assert {
    condition     = length(module.namespace) == 1
    error_message = "create_namespace must create the namespace."
  }
}

run "reject_unpinned_image" {
  command = plan
  variables {
    image = "public.ecr.aws/eks/amazon-eks-pod-identity-webhook:v0.6.17"
  }
  expect_failures = [var.image]
}

run "reject_short_token" {
  command = plan
  variables {
    token_expiration_seconds = 60
  }
  expect_failures = [var.token_expiration_seconds]
}

run "reject_zero_grace_period" {
  command = plan
  variables {
    service_account_lookup_grace_period = "0"
  }
  expect_failures = [var.service_account_lookup_grace_period]
}

run "reject_invalid_name" {
  command = plan
  variables {
    name = "Pod_Identity"
  }
  expect_failures = [var.name]
}

run "reject_invalid_selector_operator" {
  command = plan
  variables {
    bootstrap_exempt_selector_expressions = [{ key = "k8s-app", operator = "Equals", values = ["cilium"] }]
  }
  expect_failures = [var.bootstrap_exempt_selector_expressions]
}
