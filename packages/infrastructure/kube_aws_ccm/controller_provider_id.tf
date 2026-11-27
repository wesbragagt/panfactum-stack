data "pf_metadata" "metadata" {}

resource "terraform_data" "controller_provider_id" {
  for_each = var.controller_provider_ids

  triggers_replace = {
    private_ip  = each.key
    provider_id = each.value
  }

  provisioner "local-exec" {
    command = "python3 '${path.module}/scripts/controller_provider_id.py'"
    environment = {
      CONTROLLER_IDENTITY    = jsonencode(self.triggers_replace)
      PF_KUBE_CONFIG_CONTEXT = data.pf_metadata.metadata.kube_config_context
      PF_KUBE_API_SERVER     = data.pf_metadata.metadata.kube_api_server
    }
  }
}
