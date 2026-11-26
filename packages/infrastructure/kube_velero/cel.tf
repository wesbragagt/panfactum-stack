locals {
  cel_pvc_rules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["persistentvolumeclaims"] }]
  cel_pvc_conditions = [{
    name       = "pod-owned"
    expression = "object.metadata.?ownerReferences.orValue([]).exists(owner, owner.kind == 'Pod')"
    }, {
    name       = "needs-exclusion"
    expression = "object.metadata.?labels['velero.io/exclude-from-backup'].orValue('') != 'true'"
  }]
  cel_pvc_exclusion_mutations = [{ patchType = "ApplyConfiguration", applyConfiguration = {
    expression = "Object{metadata: Object.metadata{labels: {'velero.io/exclude-from-backup': 'true'}}}"
  } }]
  cel_exclude_new_pod_owned_pvcs = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "velero-exclude-new-pod-owned-pvcs", labels = module.util.labels }
    spec = {
      reinvocationPolicy = "Never"
      matchConstraints   = { resourceRules = local.cel_pvc_rules }
      matchConditions    = local.cel_pvc_conditions
      mutations          = local.cel_pvc_exclusion_mutations
    }
  }
  cel_exclude_existing_pod_owned_pvcs = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "velero-exclude-existing-pod-owned-pvcs", labels = module.util.labels }
    spec = {
      reinvocationPolicy = "Never"
      evaluation         = { admission = { enabled = true }, mutateExisting = { enabled = true } }
      matchConstraints   = { resourceRules = local.cel_pvc_rules }
      matchConditions    = local.cel_pvc_conditions
      targetMatchConstraints = {
        resourceRules = local.cel_pvc_rules
        expression    = "resource.Get('v1', 'persistentvolumeclaims', object.metadata.namespace, object.metadata.name)"
      }
      targetMatchConditions = local.cel_pvc_conditions
      mutations             = local.cel_pvc_exclusion_mutations
    }
  }
}

output "kyverno_cel_policy_documents" {
  description = "CEL policies managed by this module."
  value = [
    for policy in [local.cel_exclude_new_pod_owned_pvcs, local.cel_exclude_existing_pod_owned_pvcs] : policy
    if var.kyverno_cel_policies_enabled
  ]
}
