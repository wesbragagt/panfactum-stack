locals {
  kyverno_cel_policy_documents = [
    jsonencode(local.cel_resource_policy),
    jsonencode(local.cel_backup_gc),
    jsonencode(local.cel_backup_pdb),
  ]
}

output "kyverno_cel_policy_documents" {
  description = "CEL policy manifests for migration validation."
  value       = var.kyverno_cel_policies_enabled ? local.kyverno_cel_policy_documents : []
}
