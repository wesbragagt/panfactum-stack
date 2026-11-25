variable "cluster_name" {
  description = "Cluster identifier."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "availability_zone" {
  description = "Control-plane availability zone."
  type        = string
}

variable "vpc_id" {
  description = "Existing cluster VPC ID."
  type        = string
}

variable "subnet_id" {
  description = "Existing control-plane subnet ID."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Existing OIDC provider ARN; null retains EKS discovery."
  type        = string
  default     = null
}

variable "oidc_issuer_url" {
  description = "Existing OIDC issuer URL paired with its ARN."
  type        = string
  default     = null
}

variable "ip_restrictions_enabled" {
  description = "Enable source-IP deny policies."
  type        = bool
  default     = true
}

variable "cluster_subnet_ids" {
  description = "Explicit subnets for source-IP policy discovery."
  type        = set(string)
  default     = null
}

variable "image_version" {
  description = "AWS cloud controller manager image tag."
  type        = string
  default     = "v1.37.0"
}

variable "talos_bootstrap_enabled" {
  description = "Mount an AWS web identity token and tolerate Talos controller taints during bootstrap."
  type        = bool
  default     = false
}
