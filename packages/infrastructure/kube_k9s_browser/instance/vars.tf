# Internal module: one k9s instance. The parent module documents and defaults every input.

variable "namespace" {
  type = string
}

variable "domain" {
  type = string
}

variable "read_only" {
  type = bool
}

variable "allowed_vault_roles" {
  type = list(string)
}

variable "vault_domain" {
  type = string
}

variable "gateway_api" {
  type = object({
    parent_name      = string
    parent_namespace = string
  })
}

variable "context_name" {
  type = string
}

variable "node_selector" {
  type = map(string)
}

variable "tolerations" {
  type = list(map(string))
}

variable "controller_nodes_enabled" {
  type = bool
}

variable "instance_type_anti_affinity_required" {
  type = bool
}

variable "panfactum_scheduler_enabled" {
  type = bool
}

variable "pull_through_cache_enabled" {
  type = bool
}

variable "vpa_enabled" {
  type = bool
}
