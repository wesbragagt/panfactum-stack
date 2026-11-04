variable "cilium_helm_version" {
  description = "The version of the cilium helm chart to deploy"
  type        = string
  default     = "1.17.14"
}

variable "log_level" {
  description = "The log level for the Cilium pods"
  type        = string
  default     = "warn"
  validation {
    condition     = contains(["info", "error", "debug", "warn"], var.log_level)
    error_message = "Invalid log_level provided."
  }
}

variable "vpa_enabled" {
  description = "Whether the VPA resources should be enabled"
  type        = bool
  default     = false
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

variable "monitoring_enabled" {
  description = "Whether to add active monitoring to the deployed systems"
  type        = bool
  default     = false
}

variable "hubble_enabled" {
  description = "Whether to enable hubble for network debugging"
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
  description = "Whether to allow controller pods to schedule on spot nodes. Does not affect DaemonSet pods."
  type        = bool
  default     = true
}

variable "burstable_nodes_enabled" {
  description = "Whether to allow controller pods to schedule on burstable nodes. Does not affect DaemonSet pods."
  type        = bool
  default     = true
}

variable "controller_nodes_enabled" {
  description = "Whether to allow controller pods to schedule on EKS Node Group nodes (controller nodes). Does not affect DaemonSet pods."
  type        = bool
  default     = true
}
variable "cluster_type" {
  description = "Cluster platform. EKS preserves the existing ENI/IRSA defaults; Talos uses KubePrism and does not query EKS."
  type        = string
  default     = "eks"
  validation {
    condition     = contains(["eks", "talos"], var.cluster_type)
    error_message = "cluster_type must be eks or talos."
  }
}

variable "ipam_mode" {
  description = "Optional IPAM override. Defaults to eni on EKS and cluster-pool on Talos. ENI is not supported in Talos mode."
  type        = string
  default     = null
  validation {
    condition     = var.ipam_mode == null ? true : contains(["eni", "cluster-pool", "kubernetes"], var.ipam_mode)
    error_message = "ipam_mode must be eni, cluster-pool, kubernetes or null."
  }
}

variable "cluster_pool_ipv4_cidrs" {
  description = "Pod CIDRs used only by cluster-pool IPAM. Must match the installed cluster during adoption."
  type        = list(string)
  default     = ["10.244.0.0/16"]
}

variable "k8s_service_host" {
  description = "Agent API host override, without scheme. Defaults to the EKS endpoint or Talos KubePrism localhost."
  type        = string
  default     = null
}

variable "k8s_service_port" {
  description = "Agent API port override. Defaults to 443 for EKS and 7445 for Talos KubePrism."
  type        = number
  default     = null
}

variable "namespace" {
  description = "Helm release namespace. For adoption, preserve the existing release namespace."
  type        = string
  default     = "cilium"
}

variable "namespace_create" {
  description = "Manage the namespace and its Panfactum RBAC. Set false to use an existing namespace such as kube-system."
  type        = bool
  default     = true
}

variable "operator_replicas" {
  description = "Operator replica override. Defaults to two on EKS and one on Talos."
  type        = number
  default     = null
  validation {
    condition     = var.operator_replicas == null ? true : var.operator_replicas >= 1
    error_message = "operator_replicas must be at least one."
  }
}

variable "values_overrides" {
  description = "Additional Helm values documents merged after module defaults. Review their full diff when adopting an existing release."
  type        = list(string)
  default     = []
}
