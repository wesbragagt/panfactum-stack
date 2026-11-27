locals {
  cel_scale_selector_rules = {
    cnpg-scale-crds = {
      resource_rule = {
        apiGroups     = ["apiextensions.k8s.io"]
        apiVersions   = ["v1"]
        operations    = ["CREATE", "UPDATE"]
        resources     = ["customresourcedefinitions"]
        resourceNames = ["clusters.postgresql.cnpg.io", "poolers.postgresql.cnpg.io"]
      }
      patch_type = "JSONPatch"
      expression = <<-CEL
        [JSONPatch{op:'add',path:'/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/selector',value:{'type':'string'}},
         JSONPatch{op:'add',path:'/spec/versions/0/subresources/scale/labelSelectorPath',value:'.spec.selector'}]
      CEL
    }
    cnpg-scale-webhook = {
      resource_rule = {
        apiGroups     = ["admissionregistration.k8s.io"]
        apiVersions   = ["v1"]
        operations    = ["CREATE", "UPDATE"]
        resources     = ["mutatingwebhookconfigurations"]
        resourceNames = ["cnpg-mutating-webhook-configuration"]
      }
      patch_type = "JSONPatch"
      # NOTE: Webhook order can change across chart upgrades or when this policy reconciles.
      expression = "object.webhooks.exists(w, w.name == 'mcluster.cnpg.io') ? [JSONPatch{op:'replace',path:'/webhooks',value:object.webhooks.filter(w, w.name != 'mcluster.cnpg.io')}] : []"
    }
    cnpg-scale-clusters = {
      resource_rule = {
        apiGroups   = ["postgresql.cnpg.io"]
        apiVersions = ["v1"]
        operations  = ["CREATE", "UPDATE"]
        resources   = ["clusters"]
      }
      patch_type = "ApplyConfiguration"
      expression = "Object{spec: Object.spec{selector: 'cnpg.io/cluster=' + object.metadata.name + ',cnpg.io/podRole=instance'}}"
    }
    cnpg-scale-poolers = {
      resource_rule = {
        apiGroups   = ["postgresql.cnpg.io"]
        apiVersions = ["v1"]
        operations  = ["CREATE", "UPDATE"]
        resources   = ["poolers"]
      }
      patch_type = "ApplyConfiguration"
      expression = "object.metadata.?labels['id'].hasValue() ? Object{spec: Object.spec{selector: 'id=' + object.metadata.labels['id'] + ',cnpg.io/podRole=pooler'}} : Object{}"
    }
  }
  cel_scale_selector_policies = { for name, rule in local.cel_scale_selector_rules : name => {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = name, labels = data.pf_kube_labels.labels.labels }
    spec = {
      reinvocationPolicy = "Never"
      evaluation = {
        # NOTE: Admission queues the targeted background mutation for new resources.
        admission      = { enabled = true }
        background     = { enabled = false }
        mutateExisting = { enabled = true }
      }
      matchConstraints = { resourceRules = [rule.resource_rule] }
      targetMatchConstraints = {
        resourceRules = [rule.resource_rule]
        expression    = "resource.Get('${rule.resource_rule.apiGroups[0]}/v1', '${rule.resource_rule.resources[0]}', object.metadata.?namespace.orValue(''), object.metadata.name)"
      }
      mutations = [merge({ patchType = rule.patch_type }, rule.patch_type == "JSONPatch" ? {
        jsonPatch = { expression = rule.expression }
        } : {
        applyConfiguration = { expression = rule.expression }
      })]
    }
  } }
}

resource "kubectl_manifest" "cel_scale_selector" {
  for_each = {
    for name, policy in local.cel_scale_selector_policies : name => policy
    if var.vpa_scale_selector_policy_enabled && var.kyverno_cel_policies_enabled
  }
  yaml_body         = yamlencode(each.value)
  force_conflicts   = true
  server_side_apply = true
  depends_on = [
    helm_release.cnpg,
    kubernetes_cluster_role.kyverno_roles,
  ]
}

output "kyverno_cel_policy_documents" {
  description = "CEL policies managed by this module."
  value = [
    for policy in local.cel_scale_selector_policies : policy
    if var.vpa_scale_selector_policy_enabled && var.kyverno_cel_policies_enabled
  ]
}
