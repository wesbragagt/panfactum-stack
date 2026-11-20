variable "name" {
  description = "Prefix for AWS resources and Tailscale hostnames."
  type        = string
  default     = "tailscale-subnet-router"
}

variable "vpc_id" {
  description = "VPC the routers run in."
  type        = string
}

variable "subnets" {
  description = "Names (tag Name) of subnets for routers, each in a different AZ. The first is used alone; HA uses the first two. Subnets must assign routable public IPs or have a NAT route."
  type        = list(string)
  default     = ["PUBLIC_A", "PUBLIC_B"]
}

variable "ha_enabled" {
  description = "Run two routers in the first two subnets advertising the same routes, so Tailscale fails over between them."
  type        = bool
  default     = false
}

variable "public_ip_enabled" {
  description = "Give routers a public IPv4 so peers connect directly over UDP 41641 instead of relaying through DERP."
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "arm64 EC2 instance type for the routers."
  type        = string
  default     = "t4g.nano"
}

variable "advertised_routes" {
  description = "CIDRs the routers advertise to the tailnet. The VPC resolver /32 is added when split_dns_domains is set."
  type        = list(string)
}

variable "split_dns_domains" {
  description = "Domains (such as Route53 private zones) that tailnet clients resolve through the VPC resolver."
  type        = list(string)
  default     = []
}

variable "tailscale_tag" {
  description = "Tag the routers advertise. The OAuth client must own it, and tailnet autoApprovers should approve the routes for it."
  type        = string
  default     = "tag:aws-subnet-router"
}

variable "tailscale_oauth_client_secret" {
  description = "OAuth client secret (tskey-client-...) with the auth_keys scope. Routers read it from SSM at boot to mint their own ephemeral keys."
  type        = string
  sensitive   = true
}
