variable "name_prefix" {
  description = "Short IAM resource name prefix, without a trailing hyphen"
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,24}$", var.name_prefix))
    error_message = "name_prefix must be 1-24 IAM-compatible characters so generated role and profile names fit AWS limits."
  }
}

variable "cluster_name" {
  description = "Name of the existing self-managed Talos Kubernetes cluster"
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be 1-100 letters, digits, dots, underscores or hyphens, beginning with a letter or digit."
  }
}

variable "ecr_cache_prefixes" {
  description = "Opt-in first-import/create access to existing account/region pull-through cache prefixes; empty preserves read-only defaults."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for prefix in var.ecr_cache_prefixes : contains(["github", "docker-hub", "quay", "kubernetes", "ecr-public"], prefix)])
    error_message = "Only the five established pull-through cache prefixes are allowed."
  }
}

variable "controller_instance_id" {
  description = "Optional existing Talos controller identity opt-in. Creates a dedicated ECR-only profile; guarded in-place association refuses any conflicting profile. Does not create compute."
  type        = string
  default     = null
  validation {
    condition     = var.controller_instance_id == null ? true : can(regex("^i-[0-9a-f]+$", var.controller_instance_id))
    error_message = "controller_instance_id must be an EC2 instance ID."
  }
}

variable "controller_additional_ecr_repositories" {
  description = "Opt-in read-only access for the controller to these exact same-account/region repository names. Does not grant cache import, repository creation or image push."
  type        = set(string)
  default     = []
  validation {
    condition = alltrue([for name in var.controller_additional_ecr_repositories :
      length(name) >= 2 && length(name) <= 256 && can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", name))
    ])
    error_message = "Use exact lowercase ECR repository names without wildcards or ARNs."
  }
}
