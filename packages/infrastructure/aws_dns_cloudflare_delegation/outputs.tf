output "delegated_domains" {
  description = "Subdomains delegated to Route53 and the name servers their NS records point to."
  value       = { for domain, config in var.delegations : domain => config.name_servers }
}
