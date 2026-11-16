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

data "pf_kube_labels" "labels" {
  module = "kube_pvc_annotator"
}

resource "kubectl_manifest" "update_image_cache" {
  yaml_body = var.kyverno_cel_policies_enabled ? yamlencode(local.cel_policy) : yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "Policy"
    metadata = {
      name      = "update-pvc-metadata-${lower(substr(base64encode(sha1(join("", keys(var.config)))), 0, 6))}"
      namespace = var.namespace
      labels    = data.pf_kube_labels.labels.labels
    }
    spec = {
      useServerSideApply = true
      rules = [for group, config in var.config : {
        name = "update-pvc-metadata-${lower(substr(base64encode(sha1(group)), 0, 6))}"
        match = {
          any = [{
            resources = {
              kinds = ["PersistentVolumeClaim"]
              selector = {
                matchLabels = {
                  "panfactum.com/pvc-group" = group
                }
              }
            }
          }]
        }
        mutate = {
          mutateExistingOnPolicyUpdate = true
          targets = [{
            apiVersion = "v1"
            kind       = "PersistentVolumeClaim"
            name       = "{{ request.object.metadata.name }}"
            namespace  = var.namespace
          }]
          patchStrategicMerge = {
            metadata = {
              labels      = config.labels
              annotations = config.annotations
            }
          }
        }
      }]
      webhookConfiguration = {
        failurePolicy = "Ignore"
      }
    }
  })

  force_new         = true
  force_conflicts   = true
  server_side_apply = true
}

locals {
  cel_policy = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name   = "${var.namespace}-update-pvc-metadata-${lower(substr(base64encode(sha1(join("", keys(var.config)))), 0, 6))}"
      labels = data.pf_kube_labels.labels.labels
    }
    spec = {
      failurePolicy = "Ignore"
      evaluation    = { admission = { enabled = true }, mutateExisting = { enabled = true } }
      matchConstraints = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.namespace } }
        resourceRules     = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["persistentvolumeclaims"] }]
        objectSelector    = { matchExpressions = [{ key = "panfactum.com/pvc-group", operator = "In", values = keys(var.config) }] }
      }
      variables = [{ name = "configuration", expression = jsonencode(var.config) }]
      mutations = [{
        patchType = "ApplyConfiguration"
        applyConfiguration = {
          expression = "Object{metadata: Object.metadata{labels: variables.configuration[object.metadata.labels['panfactum.com/pvc-group']].labels, annotations: variables.configuration[object.metadata.labels['panfactum.com/pvc-group']].annotations}}"
        }
      }]
    }
  }
}
