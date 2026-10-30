variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit permission on the parent zones."
  type        = string
  sensitive   = true
}

variable "delegations" {
  description = "Subdomains to delegate (keys, e.g. homelab.example.com) with the Cloudflare zone ID of their parent domain and the Route53 name servers that should serve them (from aws_dns_zones)."
  type = map(object({
    zone_id      = string
    name_servers = list(string)
  }))
}
