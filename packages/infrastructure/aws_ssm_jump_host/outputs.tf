output "instance_id" {
  description = "EC2 instance ID to target with SSM StartSession."
  value       = aws_instance.host.id
}

output "instance_ids" {
  description = "Approved jump host EC2 instance IDs, with the primary first."
  value       = concat([aws_instance.host.id], aws_instance.secondary[*].id)
}

output "security_group_id" {
  description = "Source security group ID to allow on the target APIs."
  value       = aws_security_group.host.id
}

output "document_names" {
  description = "Session Manager port forwarding document names keyed by the caller-defined key."
  value       = { for key, document in aws_ssm_document.api : key => document.name }
}

output "document_destinations" {
  description = "Fixed Session Manager document name, remote host and remote port keyed by the caller-defined key."
  value = {
    for key, document in aws_ssm_document.api : key => {
      name = document.name
      host = local.port_forwarding_documents[key].host
      port = local.port_forwarding_documents[key].port
    }
  }
}
