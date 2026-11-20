variable "namespace" {
  description = "The namespace to create for this k9s instance"
  type        = string
}

variable "domain" {
  description = "The domain that serves this k9s instance"
  type        = string
}

variable "vault_domain" {
  description = "The domain of the Vault or OpenBao instance that users log in through"
  type        = string
}

variable "gateway_api" {
  description = "The Gateway that serves the domain"
  type = object({
    parent_name      = string
    parent_namespace = string
  })
}

variable "read_only" {
  description = "If true, k9s runs with --readonly and a ServiceAccount bound to the view ClusterRole plus read access to nodes. If false, the ServiceAccount is bound to cluster-admin."
  type        = bool
  default     = true
}

variable "allowed_vault_roles" {
  description = "The Vault groups whose members may open this instance"
  type        = list(string)
  default     = ["rbac-superusers", "rbac-admins", "rbac-readers"]
}

variable "context_name" {
  description = "The context name that k9s shows in its header"
  type        = string
  default     = "in-cluster"
}

variable "node_selector" {
  description = "Node selector for the k9s pod"
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the k9s pod"
  type        = list(map(string))
  default     = []
}

variable "controller_nodes_enabled" {
  description = "Whether the oauth2-proxy pods may run on controller nodes"
  type        = bool
  default     = true
}

variable "instance_type_anti_affinity_required" {
  description = "Whether the oauth2-proxy replicas must run on different instance types"
  type        = bool
  default     = true
}

variable "panfactum_scheduler_enabled" {
  description = "Whether the oauth2-proxy pods use the Panfactum bin-packing scheduler"
  type        = bool
  default     = true
}

variable "pull_through_cache_enabled" {
  description = "Whether the oauth2-proxy images are pulled through the ECR pull-through cache"
  type        = bool
  default     = true
}

variable "vpa_enabled" {
  description = "Whether the VPA is enabled for the oauth2-proxy pods"
  type        = bool
  default     = true
}
