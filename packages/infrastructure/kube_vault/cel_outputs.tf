locals {
  kyverno_cel_policy_documents = [
    module.pvc_annotator.cel_policy_document,
  ]
}

output "kyverno_cel_policy_documents" {
  description = "CEL policy manifests for migration validation."
  value       = var.kyverno_cel_policies_enabled ? local.kyverno_cel_policy_documents : []
}
