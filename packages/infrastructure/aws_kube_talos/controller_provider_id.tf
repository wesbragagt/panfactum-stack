resource "terraform_data" "controller_provider_id" {
  count = var.aws_node_config_enabled && (
    var.controller_provider_id_kube_api_server != null ||
    contains(["vpn", "bootstrap_public"], var.talos_access_transport) ||
    var.talos_api_endpoint == null
  ) ? local.control_plane_node_count : 0

  triggers_replace = {
    private_ip = aws_instance.control_plane[count.index].private_ip
    provider_id = format("aws:///%s/%s",
      aws_instance.control_plane[count.index].availability_zone,
      aws_instance.control_plane[count.index].id,
    )
  }

  provisioner "local-exec" {
    command = "python3 '${path.module}/scripts/controller_provider_id.py'"
    environment = {
      CONTROLLER_IDENTITY = jsonencode(self.triggers_replace)
      KUBECONFIG_RAW      = talos_cluster_kubeconfig.this.kubeconfig_raw
      KUBE_API_SERVER = coalesce(
        var.controller_provider_id_kube_api_server,
        var.talos_access_transport == "bootstrap_public" ? "https://${local.bootstrap_public_host}:6443" :
        var.talos_api_endpoint == null ? "https://${local.public_ip}:6443" :
        local.cluster_endpoint,
      )
    }
  }
}
