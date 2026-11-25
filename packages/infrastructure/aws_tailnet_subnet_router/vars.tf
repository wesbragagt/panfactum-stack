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
  description = "Run two routers advertising the same routes. The first two subnets must be in distinct availability zones."
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
  default     = null
}

variable "backend" {
  description = "Control server backend, either tailscale or headscale."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["tailscale", "headscale"], var.backend)
    error_message = "Backend must be tailscale or headscale."
  }
}

variable "headscale" {
  description = "Headscale server configuration. Required when backend is headscale."
  type = object({
    hostname = string
    zone_id  = string
  })
  default = null

  validation {
    condition = var.headscale == null ? true : (
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]*[a-z0-9]$", var.headscale.hostname)) &&
      can(regex("^Z[A-Z0-9]+$", var.headscale.zone_id))
    )
    error_message = "Headscale requires a DNS hostname and public Route 53 zone ID."
  }
}
