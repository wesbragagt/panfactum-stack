// Live

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.28.1"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  records = merge([
    for domain, config in var.delegations : {
      for ns in config.name_servers : "${domain}/${ns}" => {
        domain  = domain
        zone_id = config.zone_id
        content = ns
      }
    }
  ]...)
}

# Cloudflare's free plan cannot host a child zone, so the parent zone stays in Cloudflare
# and NS records hand the subdomain to the Route53 zone created by aws_dns_zones.
resource "cloudflare_dns_record" "ns" {
  for_each = local.records

  zone_id = each.value.zone_id
  name    = each.value.domain
  type    = "NS"
  content = each.value.content
  ttl     = 3600
  comment = "Delegated to Route53 (aws_dns_cloudflare_delegation)"
}
