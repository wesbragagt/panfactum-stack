variable "metrics_server_helm_version" {
  description = "The version of the metrics-server helm chart to deploy"
  type        = string
  default     = "3.13.0"
}

variable "vpa_enabled" {
  description = "Whether the VPA resources should be enabled"
  type        = bool
  default     = false
}

variable "pull_through_cache_enabled" {
  description = "Whether to use the ECR pull through cache for the deployed images"
  type        = bool
  default     = true
}

variable "log_verbosity" {
  description = "The log verbosity (0-9) for the metrics-server pods"
  type        = number
  default     = 5
}

variable "monitoring_enabled" {
  description = "Whether to add active monitoring to the deployed systems"
  type        = bool
  default     = false
}

variable "panfactum_scheduler_enabled" {
  description = "Whether to use the Panfactum pod scheduler with enhanced bin-packing"
  type        = bool
  default     = false
}

variable "sla_target" {
  description = "The Panfactum SLA level for the module deployment. 1 = lowest uptime (99.9%), lowest cost -- 3 = highest uptime (99.999%), highest Cost"
  type        = number
  default     = 3

  validation {
    condition     = var.sla_target <= 3 && var.sla_target >= 1
    error_message = "sla_target must be one of: 1, 2, 3"
  }
}

variable "wait" {
  description = "Wait for resources to be in a ready state before proceeding. Disabling this flag will allow upgrades to proceed faster but will disable automatic rollbacks. As a result, manual intervention may be required for deployment failures."
  type        = bool
  default     = true
}


variable "spot_nodes_enabled" {
  description = "Whether to allow pods to schedule on spot nodes"
  type        = bool
  default     = true
}

variable "burstable_nodes_enabled" {
  description = "Whether to allow pods to schedule on burstable nodes"
  type        = bool
  default     = true
}

variable "controller_nodes_enabled" {
  description = "Whether to allow pods to schedule on EKS Node Group nodes (controller nodes)"
  type        = bool
  default     = true
}

variable "serving_certificate_mode" {
  description = "Serving TLS source: panfactum uses the internal cert-manager issuer; helm uses a chart-managed certificate and verified APIService CA bundle. Helm certificates require renewal by an operator before expiry (365 days)."
  type        = string
  default     = "panfactum"
  validation {
    condition     = contains(["panfactum", "helm"], var.serving_certificate_mode)
    error_message = "serving_certificate_mode must be panfactum or helm."
  }
}

variable "replicas" {
  description = "Number of metrics-server replicas. Use one for single-node clusters."
  type        = number
  default     = 2
  validation {
    condition     = var.replicas >= 1 && floor(var.replicas) == var.replicas
    error_message = "replicas must be a positive integer."
  }
}

variable "priority_class_name" {
  description = "Override the Panfactum priority class for clusters without Panfactum core resources."
  type        = string
  default     = null
}

variable "linkerd_inject" {
  description = "Enable Linkerd injection in the metrics-server namespace."
  type        = bool
  default     = true
}

variable "kubelet_insecure_tls" {
  description = "Skip verification of kubelet serving certificates, for self-managed clusters with self-signed kubelet certificates. Does not disable APIService serving TLS verification."
  type        = bool
  default     = false
}
