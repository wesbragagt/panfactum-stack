output "role_arn" {
  description = "The ARN of the role created for the service account."
  value       = aws_iam_role.service_account.arn
}

output "role_name" {
  description = "The name of the role created for the service account."
  value       = aws_iam_role.service_account.name
}

output "policy_arn" {
  description = "The ARN of the policy assigned to the role."
  value       = aws_iam_policy.service_account.arn
}

output "service_account_annotations" {
  description = "The annotations to apply to the service account"
  value = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.service_account.arn
  }
}

output "local_credentials_secret_name" {
  description = "Secret holding AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY when local_static_credentials_enabled; null otherwise."
  value       = var.local_static_credentials_enabled ? kubernetes_secret_v1.local[0].metadata[0].name : null
}

output "local_user_arn" {
  description = "IAM user ARN behind the local static credentials; null otherwise."
  value       = var.local_static_credentials_enabled ? aws_iam_user.local[0].arn : null
}
