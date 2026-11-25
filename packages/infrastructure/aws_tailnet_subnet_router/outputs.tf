output "security_group_id" {
  description = "Router security group. Allow it on targets whose security groups restrict sources, such as the Kubernetes and Talos APIs."
  value       = aws_security_group.router.id
}

output "advertised_routes" {
  description = "Routes the routers advertise, including the VPC resolver when split DNS is on."
  value       = local.routes
}

output "hostnames" {
  description = "Tailscale hostnames of the routers."
  value       = [for r in local.routers : r.hostname]
}

output "split_dns_nameservers" {
  description = "Private domain to VPC resolver mappings. Configure these on the Headscale server when using Headscale."
  value       = { for domain in var.split_dns_domains : domain => [local.resolver] }
}

output "managed_headscale" {
  description = "Managed Headscale login URL and EC2 instance ID for Systems Manager access."
  value = var.headscale == null ? null : {
    login_server = local.headscale_url
    instance_id  = aws_instance.headscale[0].id
  }
}
