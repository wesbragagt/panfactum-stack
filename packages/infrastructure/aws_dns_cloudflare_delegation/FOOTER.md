## Maintainer Notes

Use this instead of `aws_delegated_zones` when the parent domain is hosted in Cloudflare:
`aws_delegated_zones` writes its NS and DS records into a Route53 parent zone.
Create the child zone with `aws_dns_zones` (leave `dnssec_enabled` off unless you also add the DS record in Cloudflare), then feed its `name_servers` output into `delegations`.
