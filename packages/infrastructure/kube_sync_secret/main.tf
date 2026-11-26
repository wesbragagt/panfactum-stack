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
  }
}

data "pf_kube_labels" "labels" {
  module = "kube_sync_secret"
}

resource "kubectl_manifest" "sync_secret" {
  yaml_body = var.kyverno_cel_policies_enabled ? yamlencode(local.cel_policy) : yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name   = local.policy_name
      labels = data.pf_kube_labels.labels.labels
    }
    spec = {
      rules = [
        { for k, v in {
          name = "sync-secret"
          match = {
            any = [{
              resources = { for k, v in {
                kinds = ["Namespace"]
                names = length(var.destination_namespaces) > 0 ? var.destination_namespaces : null
              } : k => v if v != null }
            }]
          }
          exclude = length(var.excluded_namespaces) > 0 ? {
            any = [{
              resources = {
                names = var.excluded_namespaces
              }
            }]
          } : null
          generate = {

            apiVersion       = "v1"
            kind             = "Secret"
            name             = var.secret_name
            namespace        = "{{request.object.metadata.name}}"
            synchronize      = true
            generateExisting = true
            clone = {
              namespace = var.secret_namespace
              name      = var.secret_name
            }
          }
        } : k => v if v != null }
      ]
    }
  })

  force_conflicts   = true
  server_side_apply = true
}

locals {
  policy_name = "sync-secret-${substr(sha1("${join(",", var.destination_namespaces)}${join(",", var.excluded_namespaces)}${var.secret_name}${var.secret_namespace}"), 0, 6)}"

  cel_policy = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "GeneratingPolicy"
    metadata = {
      name   = local.policy_name
      labels = data.pf_kube_labels.labels.labels
    }
    spec = {
      evaluation = {
        admission                      = { enabled = true }
        generateExisting               = { enabled = true }
        synchronize                    = { enabled = true }
        orphanDownstreamOnPolicyDelete = { enabled = true }
      }
      matchConstraints = {
        resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["namespaces"] }]
      }
      matchConditions = concat(
        [{ name = "source-namespace", expression = "object.metadata.name != ${jsonencode(var.secret_namespace)}" }],
        [for condition, patterns in { destinations = var.destination_namespaces, exclusions = var.excluded_namespaces } : {
          name                                     = condition
          # NOTE: Legacy namespace selectors accept * and ? as wildcards.
          expression = format(
            "%s%s.exists(pattern, object.metadata.name.matches(pattern))",
            condition == "exclusions" ? "!" : "",
            jsonencode([for pattern in patterns : format("^%s$", replace(replace(replace(pattern, "/([^a-z0-9?*-])/", "\\$1"), "*", ".*"), "?", "."))])
          )
        } if length(patterns) > 0]
      )
      variables = [{ name = "source", expression = "resource.Get('v1', 'secrets', ${jsonencode(var.secret_namespace)}, ${jsonencode(var.secret_name)})" }]
      generate  = [{ expression = "generator.Apply(object.metadata.name, [variables.source])" }]
    }
  }
}
