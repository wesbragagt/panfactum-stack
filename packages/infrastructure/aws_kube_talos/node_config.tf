locals {
  # The Talos AWS image ships ecr-credential-provider; kubelet uses it with the node's
  # instance profile to pull from the ECR pull-through cache.
  ecr_credential_provider = yamlencode({ apiVersion = "v1alpha1", kind = "KubeCredentialProviderConfig", configuration = {
    apiVersion = "kubelet.config.k8s.io/v1", kind = "CredentialProviderConfig", providers = [{
      name = "ecr-credential-provider", apiVersion = "credentialprovider.kubelet.k8s.io/v1", defaultCacheDuration = "12h", matchImages = ["*.dkr.ecr.*.amazonaws.com"]
    }]
  } })
  aws_node_patches = [
    local.ecr_credential_provider,
    # A new-style explicit DHCP config disables Talos default DHCP on hotplug ENIs.
    # Cilium owns secondary ENI addresses/routes; the host stays on the AWS primary.
    yamlencode({ apiVersion = "v1alpha1", kind = "DHCPv4Config", name = "eth0" }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeNetworkConfig", podSubnets = var.pod_subnets, serviceSubnets = var.service_subnets }),
    yamlencode({ apiVersion = "v1alpha1", kind = "UnattendedInstallConfig", installer = { image = var.installer_image }, provisioning = { diskSelector = { match = "disk.dev_path == \"/dev/sda\"" } } }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeletConfig", extraArgs = { "cloud-provider" = "external", "node-ip" = "0.0.0.0" } }),
  ]
  # Preserve document order so migration does not rewrite existing machine configs.
  aws_control_plane_patches = [local.aws_node_patches[1], local.aws_node_patches[4], local.aws_node_patches[2], local.aws_node_patches[3], local.ecr_credential_provider]
  aws_worker_patches        = concat(local.aws_node_patches, [yamlencode({ apiVersion = "v1alpha1", kind = "SysctlConfig", params = { "user.max_user_namespaces" = "2147483647" } })])
}
