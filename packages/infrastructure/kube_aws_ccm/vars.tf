variable "cluster" {
  description = "Talos cluster identity and service-account OIDC trust, as output by aws_kube_talos."
  type = object({
    name              = string
    oidc_provider_arn = string
    oidc_issuer_url   = string
  })
}

variable "controller_provider_ids" {
  description = "AWS provider ID of each controller keyed by private IP, as output by aws_kube_talos."
  type        = map(string)

  validation {
    condition     = length(var.controller_provider_ids) > 0 && alltrue([for id in values(var.controller_provider_ids) : can(regex("^aws:///[^/]+/i-[0-9a-f]+$", id))])
    error_message = "Set at least one controller provider ID in aws:///<az>/<instance-id> form."
  }
}

variable "image_version" {
  description = "AWS cloud controller manager image tag. Use the release for the cluster's Kubernetes minor."
  type        = string
  default     = "v1.36.1"
}
