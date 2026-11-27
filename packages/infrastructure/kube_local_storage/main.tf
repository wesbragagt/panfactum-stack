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
    namespace_labels   = var.namespace_labels
  })
}

locals {
  namespace_key = "/api/v1/namespaces/local-path-storage"
}

# The Namespace is created before the namespaced objects; a single for_each created them in parallel and a
# RoleBinding could reach the API before its Namespace ("the server could not find the requested resource").
resource "kubectl_manifest" "namespace" {
  yaml_body         = data.kubectl_file_documents.manifests.manifests[local.namespace_key]
  server_side_apply = true
  force_conflicts   = true
}

moved {
  from = kubectl_manifest.manifests["/api/v1/namespaces/local-path-storage"]
  to   = kubectl_manifest.namespace
}

resource "kubectl_manifest" "manifests" {
  for_each          = { for k, v in data.kubectl_file_documents.manifests.manifests : k => v if k != local.namespace_key }
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.namespace]
}

# Velero file-system backup skips hostPath volumes. The provisioner creates a `local` PV only when the PVC
# carries `volumeType: local`; it ignores the StorageClass parameter (proven on v0.0.37), so every PVC of this
# class is annotated at admission.
resource "kubectl_manifest" "local_volume_type" {
  yaml_body = var.kyverno_cel_policies_enabled ? yamlencode(local.cel_local_volume_type) : yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata   = { name = "local-path-pvc-volume-type-local" }
    spec = {
      rules = [{
        name = "annotate-volume-type-local"
        match = {
          any = [{ resources = { kinds = ["PersistentVolumeClaim"], operations = ["CREATE"] } }]
        }
        preconditions = {
          any = concat(
            [{
              key      = "{{ request.object.spec.storageClassName || '' }}"
              operator = "Equals"
              value    = var.storage_class_name
            }],
            var.default_storage_class_enabled ? [{
              key      = "{{ request.object.spec.storageClassName || '' }}"
              operator = "Equals"
              value    = ""
            }] : []
          )
        }
        mutate = {
          patchStrategicMerge = {
            metadata = { annotations = { "+(volumeType)" = "local" } }
          }
        }
      }]
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.manifests]
}
