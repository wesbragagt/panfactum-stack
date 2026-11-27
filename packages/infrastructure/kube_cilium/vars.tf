variable "namespace_labels" {
  description = "Additional namespace labels; defaults preserve existing namespace security policy"
  type        = map(string)
  default     = {}
}

variable "cilium_helm_version" {
  description = "The version of the cilium helm chart to deploy"
  type        = string
  default     = "1.20.4"
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
  default     = null
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
variable "cluster" {
  description = "Cluster identity. The aws_eks type uses EKS ENI and IRSA defaults. The talos type discovers ENI networking and OIDC from the named cluster."
  type = object({
    type = string
    name = string
  })
  default = null

  validation {
    condition     = var.cluster == null ? true : try(contains(["aws_eks", "talos"], var.cluster.type) && trimspace(var.cluster.name) != "", false)
    error_message = "cluster requires an aws_eks or talos type and a nonempty name."
  }

}

variable "cluster_type" {
  description = "Legacy platform input. EKS is the default. Local (kind) requires an explicit API host and port."
  type        = string
  default     = null
  validation {
    condition     = var.cluster_type == null ? true : contains(["eks", "talos", "local"], var.cluster_type)
    error_message = "cluster_type must be eks, talos or local."
  }
}

variable "ipam_mode" {
  description = "Optional IPAM override. Defaults to eni on EKS and on Talos when using the cluster object. Legacy Talos and local default to cluster-pool."
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
  description = "Operator replica override. Defaults to two on EKS and on discovered Talos ENI clusters with SLA target 2 or higher, one otherwise."
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

variable "oidc_provider_arn" {
  description = "Existing self-managed cluster OIDC provider ARN. Supply with oidc_issuer_url; null preserves EKS discovery."
  type        = string
  default     = null
  validation {
    condition     = var.oidc_provider_arn == null ? true : can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/.+", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be an IAM OIDC provider ARN."
  }
}
variable "oidc_issuer_url" {
  description = "HTTPS issuer URL paired with oidc_provider_arn. Custom identities require the exact namespace/service-account subject and sts.amazonaws.com audience."
  type        = string
  default     = null
  validation {
    condition     = var.oidc_issuer_url == null ? true : startswith(var.oidc_issuer_url, "https://") && !strcontains(var.oidc_issuer_url, "?")
    error_message = "oidc_issuer_url must be an HTTPS issuer URL without query parameters."
  }
}
variable "eni_subnet_ids_filter" {
  description = "Restrict newly allocated ENIs to these subnet IDs."
  type        = list(string)
  default     = []
}
variable "eni_first_interface_index" {
  description = "First interface index available for pod IP allocation."
  type        = number
  default     = null
  validation {
    condition     = var.eni_first_interface_index == null ? true : var.eni_first_interface_index >= 0 && floor(var.eni_first_interface_index) == var.eni_first_interface_index
    error_message = "eni_first_interface_index must be a nonnegative integer."
  }
}
variable "eni_cluster_tag" {
  description = "Unique cluster ownership tag for Talos ENI allocation and garbage collection. Required for Talos ENI."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Operator cluster name override. Null uses the Panfactum metadata cluster name; local clusters have none, so they set it."
  type        = string
  default     = null
}

variable "agent_extra_tolerations" {
  description = "Additional tolerations for the Cilium agent DaemonSet."
  type = list(object({
    key      = optional(string)
    operator = string
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}
