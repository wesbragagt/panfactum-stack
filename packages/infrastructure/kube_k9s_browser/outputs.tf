output "url" {
  description = "The URL of this k9s instance"
  value       = "https://${var.domain}"
}

output "service_account" {
  description = "The ServiceAccount that k9s uses; its RBAC decides what users can do"
  value       = "system:serviceaccount:${var.namespace}:k9s"
}
