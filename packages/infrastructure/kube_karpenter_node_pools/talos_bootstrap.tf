locals {
  # NOTE: The provider generates an admin Talos config even for worker-only output. The template uses only worker join data.
  talos_worker_config = local.cluster_type == "talos" && var.talos_worker_config == null && var.talos_worker_bootstrap != null ? templatefile(
    "${path.module}/talos_worker.yaml.tftpl",
    {
      cluster_name       = var.talos_worker_bootstrap.cluster_name
      cluster_endpoint   = var.talos_worker_bootstrap.cluster_endpoint
      kubernetes_version = trimprefix(var.talos_worker_bootstrap.kubernetes_version, "v")
      installer_image    = var.talos_worker_bootstrap.installer_image
      pod_subnets        = var.talos_worker_bootstrap.pod_subnets
      service_subnets    = var.talos_worker_bootstrap.service_subnets
      os_ca              = var.talos_worker_bootstrap.secrets_bundle.certs.os.crt
      kubernetes_ca      = chomp(base64decode(var.talos_worker_bootstrap.secrets_bundle.certs.k8s.crt))
      cluster_id         = var.talos_worker_bootstrap.secrets_bundle.cluster.id
      cluster_secret     = var.talos_worker_bootstrap.secrets_bundle.cluster.secret
      bootstrap_token    = var.talos_worker_bootstrap.secrets_bundle.secrets.bootstraptoken
      trust_token        = var.talos_worker_bootstrap.secrets_bundle.trustdinfo.token
    },
  ) : var.talos_worker_config
}
