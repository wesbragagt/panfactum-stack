locals {
  cluster_type  = var.cluster != null ? var.cluster.type : coalesce(var.cluster_type, "eks")
  talos_enabled = local.cluster_type == "talos"
  local_enabled = local.cluster_type == "local"
  eks_enabled   = contains(["eks", "aws_eks"], local.cluster_type)
  ipam_mode     = coalesce(var.ipam_mode, local.eks_enabled || (local.talos_enabled && var.cluster != null) ? "eni" : "cluster-pool")
  eni_enabled   = local.ipam_mode == "eni"
  routing_mode  = var.routing_mode != null ? var.routing_mode : (local.eni_enabled ? "native" : "tunnel")

  scoped_eni                 = local.talos_enabled && local.eni_enabled && var.cluster != null
  eni_iam_enabled            = local.eni_enabled && (local.eks_enabled || (local.talos_enabled && (local.scoped_eni || (var.oidc_provider_arn != null && var.oidc_issuer_url != null))))
  eni_cluster_tag            = var.eni_cluster_tag != null ? var.eni_cluster_tag : (local.scoped_eni ? local.cluster_name : null)
  eni_subnet_ids             = length(var.eni_subnet_ids_filter) > 0 ? var.eni_subnet_ids_filter : (local.scoped_eni ? [for name in sort(keys(local.private_subnets_by_name)) : local.private_subnets_by_name[name]] : [])
  eni_first_interface_index  = var.eni_first_interface_index != null ? var.eni_first_interface_index : (local.scoped_eni ? 1 : null)
  pull_through_cache_enabled = var.pull_through_cache_enabled != null ? var.pull_through_cache_enabled : !local.scoped_eni

  platform_values = merge({
    eni = merge({
      enabled                   = local.eni_enabled
      awsEnablePrefixDelegation = true
      awsReleaseExcessIPs       = true
      }, length(local.eni_subnet_ids) > 0 || local.eni_first_interface_index != null ? { nodeSpec = merge(
        length(local.eni_subnet_ids) > 0 ? { subnetIDs = local.eni_subnet_ids } : {},
        local.eni_first_interface_index != null ? { firstInterfaceIndex = local.eni_first_interface_index } : {}
      ) } : {},
      local.talos_enabled && local.eni_enabled ? {
        eniTags = { "homelab-cluster" = local.eni_cluster_tag }
        gcTags  = { "homelab-cluster" = local.eni_cluster_tag }
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

  platform_tolerations = concat(!local.eks_enabled ? [{
    key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule"
    }] : [], local.scoped_eni ? [
    { key = "node.cloudprovider.kubernetes.io/uninitialized", operator = "Exists", effect = "NoSchedule" },
    { key = "ebs.csi.aws.com/agent-not-ready", operator = "Exists", effect = "NoExecute" },
  ] : [])
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
