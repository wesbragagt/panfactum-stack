locals {
  cel_vpa_deployment_rule = {
    apiGroups     = ["apps"]
    apiVersions   = ["v1"]
    operations    = ["CREATE", "UPDATE"]
    resources     = ["deployments"]
    resourceNames = ["vpa-admission-controller", "vpa-recommender", "vpa-updater"]
  }

  cel_vpa_policies = {
    deployments = {
      apiVersion = "policies.kyverno.io/v1"
      kind       = "NamespacedMutatingPolicy"
      metadata   = { name = "adjust-vpa-deployments", namespace = local.namespace, labels = data.pf_kube_labels.labels.labels }
      spec = {
        failurePolicy = "Ignore"
        evaluation = {
          admission      = { enabled = true }
          background     = { enabled = false }
          mutateExisting = { enabled = true }
        }
        matchConstraints = { resourceRules = [local.cel_vpa_deployment_rule] }
        targetMatchConstraints = {
          resourceRules = [local.cel_vpa_deployment_rule]
          expression    = "resource.Get('apps/v1', 'deployments', object.metadata.name)"
        }
        mutations = [{
          patchType = "JSONPatch"
          jsonPatch = {
            expression = "[JSONPatch{op:'add',path:'/spec/strategy/rollingUpdate',value:{'maxSurge':0,'maxUnavailable':1}}]"
          }
        }]
      }
    }
    pods = {
      apiVersion = "policies.kyverno.io/v1"
      kind       = "NamespacedMutatingPolicy"
      metadata   = { name = "adjust-vpa-admission-pods", namespace = local.namespace, labels = data.pf_kube_labels.labels.labels }
      spec = {
        failurePolicy = "Ignore"
        evaluation    = { background = { enabled = false } }
        matchConstraints = {
          resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE"], resources = ["pods"] }]
        }
        matchConditions = [{
          name       = "admission-controller"
          expression = "object.metadata.?name.orValue('').startsWith('vpa-admission-controller') || object.metadata.?generateName.orValue('').startsWith('vpa-admission-controller')"
        }]
        mutations = [
          {
            patchType = "JSONPatch"
            jsonPatch = {
              expression = "[JSONPatch{op:'add',path:'/spec/topologySpreadConstraints',value:json.unmarshal(${jsonencode(jsonencode(module.util_admission_controller.topology_spread_constraints))})}]"
            }
          },
          {
            patchType = "JSONPatch"
            jsonPatch = {
              expression = <<-CEL
                !(object.metadata.?name.orValue('').startsWith('vpa-admission-controller-') || object.metadata.?generateName.orValue('').startsWith('vpa-admission-controller-')) ? [] :
                [JSONPatch{op:'add',path:'/spec/priorityClassName',value:'system-node-critical'}] +
                (has(object.spec.priority) ? [JSONPatch{op:'remove',path:'/spec/priority'}] : [])
              CEL
            }
          }
        ]
      }
    }
  }
}

resource "kubectl_manifest" "cel_vpa_policies" {
  for_each = { for name, policy in local.cel_vpa_policies : name => policy if var.kyverno_cel_policies_enabled }

  yaml_body         = yamlencode(each.value)
  force_conflicts   = true
  server_side_apply = true
}

output "kyverno_cel_policy_documents" {
  description = "CEL policies managed by this module."
  value       = [for policy in values(local.cel_vpa_policies) : policy if var.kyverno_cel_policies_enabled]
}
