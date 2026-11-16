terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "3.0.1"
    }
  }
}

# Upstream rancher/local-path-provisioner v0.0.37 deploy/local-path-storage.yaml
# (sha256 9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65), images pinned by digest.
data "kubectl_file_documents" "manifests" {
  content = templatefile("${path.module}/local-path-storage.yaml.tftpl", {
    provisioner_image  = var.provisioner_image
    helper_image       = var.helper_image
    host_path          = var.host_path
    reclaim_policy     = var.reclaim_policy
    storage_class_name = var.storage_class_name
    default_class      = var.default_storage_class_enabled
  })
}

resource "kubectl_manifest" "manifests" {
  for_each          = data.kubectl_file_documents.manifests.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
}
