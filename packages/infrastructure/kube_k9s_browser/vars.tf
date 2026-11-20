variable "instances" {
  description = "The k9s instances to deploy, keyed by a short name. Each gets its own namespace and domain. read_only true runs k9s with --readonly and binds the view ClusterRole plus read access to nodes; false binds cluster-admin. allowed_vault_roles are the Vault groups whose members may open the instance."
  type = map(object({
    namespace           = string
    domain              = string
    read_only           = bool
    allowed_vault_roles = list(string)
  }))
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
