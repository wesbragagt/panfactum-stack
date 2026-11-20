terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "3.0.1"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

module "instance" {
  source   = "./instance"
  for_each = var.instances

  namespace           = each.value.namespace
  domain              = each.value.domain
  read_only           = each.value.read_only
  allowed_vault_roles = each.value.allowed_vault_roles

  vault_domain                         = var.vault_domain
  gateway_api                          = var.gateway_api
  context_name                         = var.context_name
  node_selector                        = var.node_selector
  tolerations                          = var.tolerations
  controller_nodes_enabled             = var.controller_nodes_enabled
  instance_type_anti_affinity_required = var.instance_type_anti_affinity_required
  panfactum_scheduler_enabled          = var.panfactum_scheduler_enabled
  pull_through_cache_enabled           = var.pull_through_cache_enabled
  vpa_enabled                          = var.vpa_enabled
}
