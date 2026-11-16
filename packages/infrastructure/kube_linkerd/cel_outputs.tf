locals {
  kyverno_cel_policy_documents = [
    module.sync_ca_bundle.cel_policy_document,
    jsonencode(local.cel_cni_policy),
    jsonencode(local.cel_cni_ds_policy),
    jsonencode(local.cel_pod_policy),
    jsonencode(local.cel_taint_policy),
  ]
}

output "kyverno_cel_policy_documents" {
  description = "CEL policy manifests for migration validation."
  value       = var.kyverno_cel_policies_enabled ? local.kyverno_cel_policy_documents : []
}
