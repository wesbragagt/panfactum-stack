variable "velero_helm_version" {
  description = "The version of the velero helm chart"
  type        = string
  default     = "9.1.3"
}

variable "aws_plugin_version" {
  description = "The image version of the velero/velero-plugin-for-aws image"
  type        = string
  default     = "v1.12.0"
}

variable "aws_iam_ip_allow_list" {
  description = "A list of IPs that can use the service account token to authenticate with AWS API"
  type        = list(string)
  default     = []
}

variable "pull_through_cache_enabled" {
  description = "Whether to use the ECR pull through cache for the deployed images"
  type        = bool
  default     = true
}

variable "vpa_enabled" {
  description = "Whether the VPA resources should be enabled"
  type        = bool
  default     = true
}

variable "log_level" {
  description = "The log level for the Velero pods"
  type        = string
  default     = "warning"
  validation {
    condition     = contains(["info", "error", "fatal", "panic", "warning", "debug"], var.log_level)
    error_message = "Invalid log_level provided."
  }
}

variable "monitoring_enabled" {
  description = "Whether to allow monitoring CRs to be deployed in the namespace"
  type        = bool
  default     = false
}

variable "panfactum_scheduler_enabled" {
  description = "Whether to use the Panfactum pod scheduler with enhanced bin-packing"
  type        = bool
  default     = true
}

variable "wait" {
  description = "Wait for resources to be in a ready state before proceeding. Disabling this flag will allow upgrades to proceed faster but will disable automatic rollbacks. As a result, manual intervention may be required for deployment failures."
  type        = bool
  default     = true
}

variable "cleanup_crds_enabled" {
  description = "Run the destructive CRD deletion hook on uninstall; true preserves legacy behavior. Set false for retained backups."
  type        = bool
  default     = true
}

variable "extra_helm_values" {
  description = "Explicit chart values applied after module defaults"
  type        = any
  default     = {}
}

variable "oidc_provider_arn" {
  description = "Existing OIDC provider ARN; null retains EKS discovery"
  type        = string
  default     = null
}

variable "oidc_issuer_url" {
  description = "Existing OIDC issuer URL paired with its ARN"
  type        = string
  default     = null
}

variable "ip_restrictions_enabled" {
  description = "Enable source-IP deny policies for the Velero AWS role"
  type        = bool
  default     = true
}

variable "cluster_subnet_ids" {
  description = "Explicit subnets for source-IP policy discovery; null retains EKS discovery"
  type        = set(string)
  default     = null
}
