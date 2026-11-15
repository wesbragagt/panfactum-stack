locals {
  talos_enabled = var.cluster_type == "talos"
  ipam_mode     = var.ipam_mode != null ? var.ipam_mode : (local.talos_enabled ? "cluster-pool" : "eni")
  eni_enabled   = local.ipam_mode == "eni"
  routing_mode  = var.routing_mode != null ? var.routing_mode : (local.eni_enabled ? "native" : "tunnel")

  eni_iam_enabled = local.eni_enabled && (!local.talos_enabled || (var.oidc_provider_arn != null && var.oidc_issuer_url != null))

  platform_values = merge({
    eni = merge({
      enabled                   = local.eni_enabled
      awsEnablePrefixDelegation = true
      awsReleaseExcessIPs       = true
      }, length(var.eni_subnet_ids_filter) > 0 || var.eni_first_interface_index != null ? { nodeSpec = merge(
        length(var.eni_subnet_ids_filter) > 0 ? { subnetIDs = var.eni_subnet_ids_filter } : {},
        var.eni_first_interface_index != null ? { firstInterfaceIndex = var.eni_first_interface_index } : {}
      ) } : {},
      local.talos_enabled && local.eni_enabled ? {
        eniTags = { "homelab-cluster" = var.eni_cluster_tag }
        gcTags  = { "homelab-cluster" = var.eni_cluster_tag }
    } : {})
    ipam = merge({ mode = local.ipam_mode }, local.ipam_mode == "cluster-pool" ? {
      operator = { clusterPoolIPv4PodCIDRList = var.cluster_pool_ipv4_cidrs }
    } : {})
    enableIPv4Masquerade       = !local.eni_enabled
    egressMasqueradeInterfaces = "eth0"
    routingMode                = local.routing_mode
    }, var.ipv4_native_routing_cidr == null ? {} : {
    ipv4NativeRoutingCIDR = var.ipv4_native_routing_cidr
    }, { for key, value in {
      securityContext = {
        capabilities = {
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }
      cgroup = { autoMount = { enabled = false }, hostRoot = "/sys/fs/cgroup" }
  } : key => value if local.talos_enabled })

  operator_web_identity = { for key, value in {
    extraVolumes = [{
      name = "aws-web-identity"
      projected = { sources = [{ serviceAccountToken = {
        audience = "sts.amazonaws.com", expirationSeconds = 86400, path = "token"
      } }] }
    }]
    extraVolumeMounts = [{
      name = "aws-web-identity", mountPath = "/var/run/secrets/eks.amazonaws.com/serviceaccount", readOnly = true
    }]
  } : key => value if local.talos_enabled && local.eni_enabled }

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
