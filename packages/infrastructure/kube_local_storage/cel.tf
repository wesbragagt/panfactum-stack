locals {
  cel_local_volume_type = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata   = { name = "local-path-pvc-volume-type-local" }
    spec = {
      reinvocationPolicy = "Never"
      matchConstraints = {
        resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE"], resources = ["persistentvolumeclaims"] }]
      }
      matchConditions = [{
        name       = "local-storage-class"
        expression = "object.spec.?storageClassName.orValue('') in ${jsonencode(var.default_storage_class_enabled ? [var.storage_class_name, ""] : [var.storage_class_name])}"
      }]
      mutations = [{ patchType = "JSONPatch", jsonPatch = {
        expression = <<-CEL
          !has(object.metadata.annotations) ?
          [JSONPatch{op:'add',path:'/metadata/annotations',value:{'volumeType':'local'}}] :
          ('volumeType' in object.metadata.annotations ? [] :
          [JSONPatch{op:'add',path:'/metadata/annotations/volumeType',value:'local'}])
        CEL
      } }]
    }
  }
}

output "kyverno_cel_policy_documents" {
  description = "CEL policy managed by this module."
  value       = var.kyverno_cel_policies_enabled ? [local.cel_local_volume_type] : []
}
