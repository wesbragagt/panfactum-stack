output "cel_policy_document" {
  description = "CEL policy manifest for migration validation."
  value       = jsonencode(local.cel_policy)
}
