// Talos supplies all Custom AMI bootstrap data itself; Karpenter must not merge EKS user data.
resource "kubectl_manifest" "talos_node_class" {
  count = var.cluster_type == "talos" ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = var.talos_node_pool_name, labels = data.pf_kube_labels.labels.labels }
    spec = {
      amiFamily                  = "Custom"
      amiSelectorTerms           = [{ id = var.talos_ami_id }]
      subnetSelectorTerms        = [for subnet in data.aws_subnet.node_subnets : { id = subnet.id }]
      securityGroupSelectorTerms = [{ id = var.node_security_group_id }]
      instanceProfile            = var.node_instance_profile
      associatePublicIPAddress   = false
      detailedMonitoring         = false
      userData                   = var.talos_worker_config
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 1
      }
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs        = { volumeSize = "${var.node_ebs_volume_size_gb}Gi", volumeType = "gp3", encrypted = true, deleteOnTermination = true }
      }]
    }
  })
  server_side_apply = true
  sensitive_fields  = ["spec.userData"]
  force_conflicts   = true
  lifecycle {
    precondition {
      condition     = var.talos_ami_id != null && var.talos_worker_config != null
      error_message = "Talos requires a pinned AMI and worker-only config."
    }
    precondition {
      condition     = var.talos_worker_config == null ? true : !strcontains(var.talos_worker_config, "PRIVATE KEY")
      error_message = "Worker bootstrap must never contain private signing keys."
    }
  }
}
resource "kubectl_manifest" "talos_node_pool" {
  count = var.cluster_type == "talos" ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = var.talos_node_pool_name, labels = data.pf_kube_labels.labels.labels }
    spec = {
      limits = { cpu = tostring(var.talos_cpu_limit), memory = var.talos_memory_limit }
      disruption = {
        consolidationPolicy = var.talos_consolidation_policy
        consolidateAfter    = "60s"
        budgets = concat(
          [{ nodes = "1" }],
          var.talos_drift_disruption_enabled ? [] : [{ nodes = "0", reasons = ["Drifted"] }]
        )
      }
      template = {
        metadata = { labels = merge(var.node_labels, { "panfactum.com/class" = "spot" }) }
        spec = {
          nodeClassRef  = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = var.talos_node_pool_name }
          taints        = var.talos_taints_enabled ? concat(local.spot_taints, var.talos_architecture == "arm64" ? local.arm_taints : []) : []
          startupTaints = var.talos_startup_taints
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot"] },
            { key = "kubernetes.io/arch", operator = "In", values = [var.talos_architecture] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.k8s.aws/instance-cpu", operator = "In", values = ["2"] },
            { key = "karpenter.k8s.aws/instance-memory", operator = "Gt", values = ["4095"] },
            { key = "karpenter.k8s.aws/instance-memory", operator = "Lt", values = ["8193"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = var.talos_instance_families }
          ]
          expireAfter            = "Never"
          terminationGracePeriod = "2m"
        }
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.talos_node_class]
}
