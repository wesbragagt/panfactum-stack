locals {
  kyverno_cel_policy_documents = [
    module.sync_ca_bundle.cel_policy_document,
  ]
}

output "kyverno_cel_policy_documents" {
  description = "CEL policy manifests for migration validation."
  value       = var.kyverno_cel_policies_enabled ? local.kyverno_cel_policy_documents : []
}
