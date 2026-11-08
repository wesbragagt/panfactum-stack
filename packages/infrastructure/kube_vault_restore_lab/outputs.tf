output "namespace" {
  description = "Dedicated lab namespace."
  value       = local.namespace_name
}
output "service_name" {
  description = "Private lab API Service; never the production vault-active Service."
  value       = kubernetes_service_v1.server.metadata[0].name
}
output "persistent_volume_claim" {
  description = "Dedicated recovery PVC; include its live UID and volume identity in any cleanup approval."
  value       = kubernetes_persistent_volume_claim_v1.lab.metadata[0].name
}
output "role_arn" {
  description = "KMS-only projected identity for the isolated process."
  value       = module.aws_auth.role_arn
}
