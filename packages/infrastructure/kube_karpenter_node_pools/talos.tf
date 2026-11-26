locals {
  talos_ami_id      = var.talos_launch == null ? var.talos_ami_id : var.talos_launch.ami_id
  talos_worker_docs = [for doc in split("\n---\n", local.talos_worker_config == null ? "" : local.talos_worker_config) : yamldecode(doc) if trimspace(doc) != ""]

  // Per-class kubelet shutdown periods from kube_node_settings (is_spot for spot and burstable).
  talos_shutdown_grace_periods = { default = "60m0s", spot = "2m0s", burstable = "2m0s" }

  // The [*] splat is empty when talos_kubelet_reservations is null, so nothing is added to today's output.
  talos_kubelet_shared = merge([for r in var.talos_kubelet_reservations[*] : {
    maxPods                     = 110
    kubeReserved                = r.kube_reserved
    evictionHard                = r.eviction_hard
    imageGCHighThresholdPercent = r.image_gc_high_threshold_percent
    imageGCLowThresholdPercent  = r.image_gc_low_threshold_percent
  }]...)
  talos_kubelet_runtime = merge(local.talos_kubelet_shared, [for r in var.talos_kubelet_reservations[*] : {
    systemReserved         = r.system_reserved
    enforceNodeAllocatable = ["pods"]
  }]...)
  // The modeled storage reserve exists only for Karpenter's forecast and must not shrink the runtime kubelet budget.
  talos_node_class_kubelet = merge({ maxPods = 110 }, local.talos_kubelet_shared, [for r in var.talos_kubelet_reservations[*] : {
    systemReserved = merge(r.system_reserved, { "ephemeral-storage" = r.node_class_system_ephemeral_storage })
  }]...)

  // Karpenter rejects nodes that do not register with this taint; only Karpenter-launched workers get it.
  // Karpenter applies each pool's labels and taints, so the ASG worker labels/taints are dropped.
  talos_user_data = { for class, period in local.talos_shutdown_grace_periods : class => join("---\n", [for doc in local.talos_worker_docs :
    try(doc.kind, "") == "KubeletConfig" ? yamlencode(merge(doc, { config = merge(try(doc.config, {}), local.talos_kubelet_runtime, {
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
  for_each = local.cluster_type == "talos" ? local.talos_node_class_names : {}
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = each.value, labels = data.pf_kube_labels.labels.labels }
    spec = {
      amiFamily                  = "Custom"
      amiSelectorTerms           = [{ id = local.talos_ami_id }]
      subnetSelectorTerms        = [for subnet in data.aws_subnet.node_subnets : { id = subnet.id }]
      securityGroupSelectorTerms = [{ id = var.talos_launch == null ? var.node_security_group_id : var.talos_launch.security_group_id }]
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
      kubelet = local.talos_node_class_kubelet
    }
  })
  server_side_apply = true
  sensitive_fields  = ["spec.userData"]
  force_conflicts   = true
  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = local.talos_ami_id != null && local.talos_worker_config != null
      error_message = "Talos requires a pinned AMI and worker-only config."
    }
    precondition {
      condition = var.talos_worker_config != null || var.talos_worker_bootstrap == null ? true : try(
        startswith(trimprefix(var.talos_worker_bootstrap.talos_version, "v"), "1.") &&
        tonumber(split(".", var.talos_worker_bootstrap.talos_version)[1]) >= 14,
        false,
      )
      error_message = "Generated worker config requires Talos v1.14 or later in the v1 series. For earlier or custom configurations, supply talos_worker_config."
    }
    precondition {
      condition = local.talos_worker_config == null ? true : (
        alltrue([for doc in local.talos_worker_docs :
          try(doc.machine.type, "worker") == "worker" &&
          !strcontains(upper(jsonencode(doc)), "PRIVATE KEY") &&
          alltrue([for key in [
            try(doc.machine.ca.key, null),
            try(doc.cluster.ca.key, null),
            try(doc.cluster.aggregatorCA.key, null),
            try(doc.cluster.etcd.ca.key, null),
            try(doc.cluster.serviceAccount.key, null),
            try(doc.issuingCA.key, null),
            try(doc.issuer.privateKey, null),
          ] : key == null || key == ""])
        ])
      )
      error_message = "Use only worker machine configuration without private signing keys."
    }
    precondition {
      condition     = alltrue([for r in var.talos_kubelet_reservations[*] : r.modeled_volume_size_gb == var.node_ebs_volume_size_gb])
      error_message = "talos_kubelet_reservations.node_class_system_ephemeral_storage was measured for a different root volume size. Re-measure filesystem loss for node_ebs_volume_size_gb, then set both fields."
    }
  }
}
