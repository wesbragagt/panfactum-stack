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
