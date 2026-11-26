locals {
  aws_control_plane_patches = [
    # NOTE: Explicit DHCP on the primary ENI leaves secondary ENIs for Cilium.
    yamlencode({ apiVersion = "v1alpha1", kind = "DHCPv4Config", name = "eth0" }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeletConfig", extraArgs = { "cloud-provider" = "external", "node-ip" = "0.0.0.0" } }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeNetworkConfig", podSubnets = var.pod_subnets, serviceSubnets = var.service_subnets }),
    yamlencode({ apiVersion = "v1alpha1", kind = "UnattendedInstallConfig", installer = { image = var.installer_image }, provisioning = { diskSelector = { match = "disk.dev_path == \"/dev/sda\"" } } }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeCredentialProviderConfig", configuration = {
      apiVersion = "kubelet.config.k8s.io/v1", kind = "CredentialProviderConfig", providers = [{
        name = "ecr-credential-provider", apiVersion = "credentialprovider.kubelet.k8s.io/v1", defaultCacheDuration = "12h", matchImages = ["*.dkr.ecr.*.amazonaws.com"]
      }]
    } }),
  ]
}
