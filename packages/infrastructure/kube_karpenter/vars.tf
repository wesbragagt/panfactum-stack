variable "karpenter_helm_version" {
  description = "The Karpenter chart version. Null uses the platform default."
  type        = string
  default     = null
}

variable "node_role_arn" {
  description = "Worker EC2 IAM role ARN permitted by iam:PassRole, including the role attached to an existing worker instance profile."
  type        = string
  default     = null
  validation {
    condition = var.talos_worker_identity == null && var.cluster == null ? (
      var.node_role_arn == null ? false : trimspace(var.node_role_arn) != ""
      ) : (
      var.node_role_arn == null && var.existing_instance_profile_arn == null
    )
    error_message = "Provide node_role_arn for an external worker identity. Omit node_role_arn and existing_instance_profile_arn for a managed Talos identity."
  }
}

variable "cluster" {
  description = "Talos cluster connection and OIDC settings. Talos clusters use a managed worker identity."
  type = object({
    type              = string
    name              = string
    endpoint          = string
    oidc_provider_arn = string
    oidc_issuer_url   = string
  })
  default = null

  validation {
    condition = var.cluster == null ? true : (
      var.cluster.type == "talos" &&
      alltrue([for value in [var.cluster.name, var.cluster.endpoint, var.cluster.oidc_provider_arn, var.cluster.oidc_issuer_url] : try(length(trimspace(value)) > 0, false)]) &&
      var.cluster_name == null && var.cluster_endpoint == null &&
      var.oidc_provider_arn == null && var.oidc_issuer_url == null
    )
    error_message = "Set cluster.type to talos and provide its name, endpoint, and OIDC settings. Omit the corresponding individual inputs."
  }
}

variable "talos_worker_identity" {
  description = "Optional Talos worker IAM name and ECR cache overrides. Setting this also enables managed identity for legacy callers."
  type = object({
    name_prefix        = optional(string)
    ecr_cache_prefixes = optional(set(string), [])
  })
  default = null

  validation {
    condition = var.talos_worker_identity == null ? true : (
      var.talos_worker_identity.name_prefix == null ? true :
      can(regex("^[A-Za-z0-9+=,.@_-]{1,24}$", var.talos_worker_identity.name_prefix))
    )
    error_message = "talos_worker_identity.name_prefix must be 1-24 IAM-compatible characters."
  }

  validation {
    condition = var.talos_worker_identity == null ? true : alltrue([
      for prefix in var.talos_worker_identity.ecr_cache_prefixes :
      contains(["github", "docker-hub", "quay", "kubernetes", "ecr-public"], prefix)
    ])
    error_message = "Use only established ECR cache prefixes for Talos workers."
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
  default     = false
}

variable "log_level" {
  description = "The log level for the karpenter pods"
  type        = string
  default     = "warn"
  validation {
    condition     = contains(["info", "error", "warn", "debug"], var.log_level)
    error_message = "Invalid log_level provided."
  }
}

variable "monitoring_enabled" {
  description = "Whether to add active monitoring to the deployed systems"
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

variable "cluster_name" {
  description = "Override the metadata cluster name, including AWS resource tags and Karpenter settings."
  type        = string
  default     = null
}

variable "cluster_endpoint" {
  description = "Explicit reachable Kubernetes API endpoint for self-managed clusters; disables EKS endpoint-discovery permission."
  type        = string
  default     = null
}

variable "aws_region" {
  description = "Explicit AWS region for controller SDK and IAM resource scope. Must match the AWS provider region; disables IMDS discovery."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "Optional VPC scope for EC2 launch subnet/security-group permissions. NodeClass selectors must target the same VPC."
  type        = string
  default     = null
}

variable "existing_instance_profile_arn" {
  description = "Existing external worker instance profile ARN for scoped read permission. Configure its name on EC2NodeClass separately."
  type        = string
  default     = null
}

variable "manage_instance_profiles_enabled" {
  description = "Allow Karpenter to create and update instance profiles for callers with an external node role. The Talos-managed identity uses a fixed profile."
  type        = bool
  default     = true
}

variable "worker_nodes_preferred" {
  description = "Prefer on-demand and Spot workers, with controller nodes eligible as fallback."
  type        = bool
  default     = false
}

variable "replicas" {
  description = "Controller replicas; null retains the SLA-based existing replica count."
  type        = number
  default     = null
  validation {
    condition     = var.replicas == null ? true : (var.replicas >= 1 && floor(var.replicas) == var.replicas)
    error_message = "replicas must be null or a positive integer."
  }
}

variable "namespace_linkerd_inject" {
  description = "Enable namespace mesh injection. Controller Pod itself always explicitly disables injection."
  type        = bool
  default     = true
}

variable "extra_helm_values" {
  description = "Additional Helm values merged after module defaults."
  type        = any
  default     = {}
}

variable "oidc_provider_arn" {
  description = "Explicit shared self-managed AWS OIDC provider ARN."
  type        = string
  default     = null
}

variable "oidc_issuer_url" {
  description = "Explicit shared self-managed OIDC issuer URL."
  type        = string
  default     = null
}

variable "cluster_subnet_ids" {
  description = "Forwarded subnet inputs for service-account IAM IP restrictions."
  type        = list(string)
  default     = null
}

variable "ip_restrictions_enabled" {
  description = "Whether the service-account IAM role uses IP restrictions."
  type        = bool
  default     = true
}

variable "additional_controller_policy_json" {
  description = "Additional AWS controller policy document for explicitly reviewed version-specific permissions; statement SIDs must not collide with module-owned statements."
  type        = string
  default     = null
}
