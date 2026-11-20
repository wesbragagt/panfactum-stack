data "talos_machine_configuration" "worker_on_demand" {
  count              = var.aws_node_config_enabled && length(var.on_demand_worker_subnets) > 0 ? 1 : 0
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.worker_cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = local.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false
  examples           = false
  config_patches = concat(local.aws_worker_patches, [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeNodeConfig", registerWithFQDN = true, labels = { "panfactum.com/class" = "worker", "node.kubernetes.io/lifecycle" = "on-demand" } })
  ])
}
resource "aws_launch_template" "worker_on_demand" {
  count         = var.aws_node_config_enabled && length(var.on_demand_worker_subnets) > 0 ? 1 : 0
  name_prefix   = "${var.cluster_name}-worker-od-"
  image_id      = data.aws_ami.talos.id
  instance_type = var.worker_instance_type
  user_data     = base64encode(data.talos_machine_configuration.worker_on_demand[0].machine_configuration)
  iam_instance_profile {
    arn = var.worker_instance_profile_arn
  }
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.nodes.id]
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = data.aws_ami.talos.root_device_name
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = merge(data.pf_aws_tags.tags.tags, { Name = "${var.cluster_name}-worker-od" })
  }
  tags = data.pf_aws_tags.tags.tags
}
