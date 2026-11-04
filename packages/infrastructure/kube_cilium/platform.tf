locals {
  talos_enabled = var.cluster_type == "talos"
  ipam_mode     = var.ipam_mode != null ? var.ipam_mode : (local.talos_enabled ? "cluster-pool" : "eni")
  eni_enabled   = !local.talos_enabled && local.ipam_mode == "eni"

  platform_values = merge({
    eni = {
      enabled                   = local.eni_enabled
      awsEnablePrefixDelegation = true
      awsReleaseExcessIPs       = true
    }
    ipam = merge({ mode = local.ipam_mode }, local.ipam_mode == "cluster-pool" ? {
      operator = { clusterPoolIPv4PodCIDRList = var.cluster_pool_ipv4_cidrs }
    } : {})
    enableIPv4Masquerade       = !local.eni_enabled
    egressMasqueradeInterfaces = "eth0"
    routingMode                = local.eni_enabled ? "native" : "tunnel"
    }, { for key, value in {
      securityContext = {
        capabilities = {
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }
      cgroup = { autoMount = { enabled = false }, hostRoot = "/sys/fs/cgroup" }
  } : key => value if local.talos_enabled })

  platform_tolerations = local.talos_enabled ? [{
    key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule"
  }] : []
}

# Keep EKS state addresses stable when the optional resources become conditional.
moved {
  from = module.namespace
  to   = module.namespace[0]
}
moved {
  from = module.aws_permissions
  to   = module.aws_permissions[0]
}
moved {
  from = kubernetes_annotations.service_account
  to   = kubernetes_annotations.service_account[0]
}
