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
