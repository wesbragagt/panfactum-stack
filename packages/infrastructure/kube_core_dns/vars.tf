variable "core_dns_image_version" {
  description = "The version of the image to use for the deployment"
  type        = string
  default     = "1.14.2"
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

variable "service_ip" {
  description = "The IP address that the DNS service will be exposed on"
  type        = string
  default     = "172.20.0.10"
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

variable "instance_type_anti_affinity_required" {
  description = "Whether to require CoreDNS replicas to run on different instance types"
  type        = bool
  default     = true
}

variable "max_surge" {
  description = "Maximum number or percentage of extra CoreDNS pods during a rollout"
  type        = string
  default     = "0%"
}

variable "max_unavailable" {
  description = "Maximum number of unavailable CoreDNS pods during a rollout"
  type        = number
  default     = 1
}

variable "replicas" {
  description = "CoreDNS replica count. Keep the default of 2 on multi-node clusters; single-node local clusters use 1 because instance-type anti-affinity leaves a second replica unschedulable."
  type        = number
  default     = 2
  validation {
    condition     = var.replicas >= 1
    error_message = "replicas must be at least one."
  }
}

variable "namespace" {
  description = "The namespace to deploy CoreDNS into"
  type        = string
  default     = "core-dns"
}

variable "namespace_create" {
  description = "Whether to create the namespace"
  type        = bool
  default     = true
}

variable "namespace_labels" {
  description = "Additional namespace labels"
  type        = map(string)
  default     = {}
}

variable "name_rewrites" {
  description = "Exact DNS names answered as the given cluster Service name (for example a local gateway)"
  type        = map(string)
  default     = {}
  validation {
    # A target outside the cluster zone would be forwarded upstream and could loop back to a rewritten name.
    condition = alltrue([for name, target in var.name_rewrites :
      endswith(target, ".svc.cluster.local") && !endswith(name, ".cluster.local") && !contains(keys(var.name_rewrites), target)
    ])
    error_message = "name_rewrites targets must be *.svc.cluster.local Service names, and sources must be outside cluster.local."
  }
}
