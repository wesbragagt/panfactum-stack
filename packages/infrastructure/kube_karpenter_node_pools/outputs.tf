output "user_data" {
  value     = var.cluster_type == "talos" ? var.talos_worker_config : module.node_settings[0].user_data
  sensitive = true
}
