output "namespace" {
  value = local.namespace
}

output "annotation_key" {
  description = "ServiceAccount annotation the webhook reads for the IAM role ARN."
  value       = "eks.amazonaws.com/role-arn"
}

output "webhook_service_name" {
  value = kubernetes_service_v1.webhook.metadata[0].name
}
