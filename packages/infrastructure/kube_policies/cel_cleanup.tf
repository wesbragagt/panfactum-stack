locals {
  cel_released_pv_gc = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "DeletingPolicy"
    metadata   = { name = "released-pv-gc", labels = data.pf_kube_labels.labels.labels }
    spec = {
      schedule = "* * * * *"
      matchConstraints = {
        resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["*"], resources = ["persistentvolumes"] }]
      }
      conditions = [{
        name       = "released-past-retention"
        expression = "has(object.status) && has(object.status.phase) && object.status.phase == 'Released' && has(object.status.lastPhaseTransitionTime) && time.now() - timestamp(object.status.lastPhaseTransitionTime) > duration('${var.gc_released_volumes_after_days * 24}h')"
      }]
    }
  }
  cel_update_request_gc = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "DeletingPolicy"
    metadata   = { name = "update-request-gc", labels = data.pf_kube_labels.labels.labels }
    spec = {
      schedule = "15 * * * *"
      matchConstraints = {
        resourceRules = [{ apiGroups = ["kyverno.io"], apiVersions = ["v2"], operations = ["*"], resources = ["updaterequests"] }]
      }
      conditions = [{
        name       = "older-than-24-hours"
        expression = "time.now() - timestamp(object.metadata.creationTimestamp) > duration('24h')"
      }]
    }
  }
}

output "kyverno_cel_cleanup_policy_documents" {
  description = "CEL cleanup policies managed by this module."
  value = var.kyverno_cel_policies_enabled ? concat(
    var.gc_released_volumes_after_days > -1 ? [local.cel_released_pv_gc] : [],
    [local.cel_update_request_gc]
  ) : []
}
