locals {
  talos_worker_docs = [for doc in split("\n---\n", var.talos_worker_config == null ? "" : var.talos_worker_config) : yamldecode(doc) if trimspace(doc) != ""]

  // Per-class kubelet shutdown periods from kube_node_settings (is_spot for spot and burstable).
  talos_shutdown_grace_periods = { default = "60m0s", spot = "2m0s", burstable = "2m0s" }

  // Karpenter rejects nodes that do not register with this taint; only Karpenter-launched workers get it.
  // Karpenter applies each pool's labels and taints, so the ASG worker labels/taints are dropped.
  talos_user_data = { for class, period in local.talos_shutdown_grace_periods : class => join("---\n", [for doc in local.talos_worker_docs :
    try(doc.kind, "") == "KubeletConfig" ? yamlencode(merge(doc, { config = merge(try(doc.config, {}), {
      registerWithTaints              = [{ key = "karpenter.sh/unregistered", effect = "NoExecute" }]
      shutdownGracePeriod             = period
      shutdownGracePeriodCriticalPods = "30s"
    }) })) :
    try(doc.kind, "") == "KubeNodeConfig" ? yamlencode({ for k, v in doc : k => v if !contains(["labels", "taints"], k) }) :
    yamlencode(doc)
  ]) }

  talos_node_class_names = {
    default   = random_id.default_node_class_name[0].hex
    spot      = random_id.spot_node_class_name[0].hex
    burstable = random_id.burstable_node_class_name[0].hex
  }
}

// Talos supplies all Custom AMI bootstrap data itself; Karpenter must not merge EKS user data.
resource "kubectl_manifest" "talos_node_class" {
  for_each = var.cluster_type == "talos" ? local.talos_node_class_names : {}
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = each.value, labels = data.pf_kube_labels.labels.labels }
    spec = {
      amiFamily                  = "Custom"
      amiSelectorTerms           = [{ id = var.talos_ami_id }]
      subnetSelectorTerms        = [for subnet in data.aws_subnet.node_subnets : { id = subnet.id }]
      securityGroupSelectorTerms = [{ id = var.node_security_group_id }]
      instanceProfile            = var.node_instance_profile
      userData                   = local.talos_user_data[each.key]
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
      kubelet = {
        maxPods = 110
      }
    }
  })
  server_side_apply = true
  sensitive_fields  = ["spec.userData"]
  force_conflicts   = true
  lifecycle {
    create_before_destroy = true
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
