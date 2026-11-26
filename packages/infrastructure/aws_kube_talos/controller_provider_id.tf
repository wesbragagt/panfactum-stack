resource "terraform_data" "controller_provider_id" {
  count = (
    var.controller_provider_id_kube_api_server != null ||
    (local.ccm_host_networking && local.ccm_ssm) ||
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
    environment = merge(local.ccm_kubectl_environment, {
      CONTROLLER_IDENTITY  = jsonencode(self.triggers_replace)
      KUBE_API_SERVER      = coalesce(var.controller_provider_id_kube_api_server, local.ccm_api_server)
      KUBE_TLS_SERVER_NAME = var.controller_provider_id_kube_api_server == null ? local.ccm_tls_server_name : ""
    })
  }
}
