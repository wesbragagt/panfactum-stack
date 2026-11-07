output "node_role_arn" {
  description = "EC2 worker IAM role ARN for Karpenter's scoped PassRole policy"
  value       = aws_iam_role.worker.arn
}

output "node_instance_profile" {
  description = "Existing instance profile name to pass to the Custom EC2NodeClass"
  value       = aws_iam_instance_profile.worker.name
}

output "node_instance_profile_arn" {
  description = "EC2 worker instance profile ARN"
  value       = aws_iam_instance_profile.worker.arn
}

output "controller_instance_profile" {
  description = "Optional ECR-only controller profile; guarded association is tracked without compute ownership."
  value       = try(aws_iam_instance_profile.controller[0].name, null)
}
