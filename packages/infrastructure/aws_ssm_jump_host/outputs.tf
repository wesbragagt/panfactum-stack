output "instance_id" {
  description = "EC2 instance ID to target with SSM StartSession."
  value       = aws_instance.host.id
}

output "security_group_id" {
  description = "Source security group ID to allow on the target APIs."
  value       = aws_security_group.host.id
}

output "document_names" {
  description = "Session Manager port forwarding document names keyed by the caller-defined key."
  value       = { for key, document in aws_ssm_document.api : key => document.name }
}
