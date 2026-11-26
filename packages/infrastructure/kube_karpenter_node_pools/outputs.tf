output "user_data" {
  value     = local.cluster_type == "talos" ? local.talos_worker_config : module.node_settings[0].user_data
  sensitive = true
}
