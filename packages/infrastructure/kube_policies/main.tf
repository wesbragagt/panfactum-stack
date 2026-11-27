terraform {
  required_providers {
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
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
  }
}

// Only the ECR pull-through registry needs the account ID; skipping the STS call lets clusters without AWS plan.
data "aws_caller_identity" "current" {
  count = var.pull_through_cache_enabled ? 1 : 0
}
data "aws_region" "current" {}


data "pf_kube_labels" "labels" {
  module = "kube_policies"
}

module "constants" {
  source = "../kube_constants"
}

locals {
  match_any_pod = {
    any = [
      {
        resources = {
          kinds      = ["Pod"]
          operations = ["CREATE", "UPDATE"]
        }
      }
    ]
  }
  match_any_pod_create = {
    any = [
      {
        resources = {
          kinds      = ["Pod"]
          operations = ["CREATE"]
        }
      }
    ]
  }
}

moved {
  from = kubectl_manifest.panfactum_policies
  to   = kubectl_manifest.panfactum_policies[0]
}

resource "kubectl_manifest" "panfactum_policies" {
  count = var.kyverno_cel_policies_enabled ? 0 : 1

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name   = "pf-pod-policies"
      labels = data.pf_kube_labels.labels.labels
      annotations = {
        "pod-policies.kyverno.io/autogen-controllers" = "none"
      }
    }
    spec = {
      // The order here is EXTREMELY important. Do not change unless you know what you are doing.
      rules = [for rule in concat(
        local.rule_cilium_test,
        local.rule_disable_linkerd,
        var.cluster_wide_pull_through_cache_enabled ? [] : local.rule_use_pull_through_image_cache,
        local.rule_use_panfactum_scheduler,
        local.rule_add_default_tolerations,
        local.rule_add_extra_tolerations_if_controller_toleration,
        local.rule_add_environment_variables,
        local.rule_add_pod_label
      ) : rule if rule != null]


      webhookConfiguration = {
        // By default, the webhook should not fail if the pod mutations cannot be applied
        // as this can end up in a dead-locked cluster
        failurePolicy = "Ignore"

        // This can sometimes exceed the context deadline which can cause issues
        timeoutSeconds = 30
      }
    }
  })

  force_new         = true
  force_conflicts   = true
  server_side_apply = true

  depends_on = [
    kubectl_manifest.pull_through_cache_binding,
    kubectl_manifest.linkerd_destination_global_context,
    kubectl_manifest.linkerd_identity_global_context,
    kubectl_manifest.scheduler_global_context,
    module.secret_sync
  ]
}


