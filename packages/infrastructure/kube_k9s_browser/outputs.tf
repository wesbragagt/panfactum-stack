output "url" {
  description = "The URL of each k9s instance, keyed like var.instances"
  value       = { for k, v in var.instances : k => "https://${v.domain}" }
}

output "service_account" {
  description = "The ServiceAccount that each k9s instance uses, keyed like var.instances; its RBAC decides what users can do"
  value       = { for k, v in var.instances : k => "system:serviceaccount:${v.namespace}:k9s" }
}
