locals {
  node_instance_types = toset(concat(
    length(var.control_plane_instance_types) > 0 ? var.control_plane_instance_types : [var.control_plane_instance_type],
    var.ssm_jump_host_enabled ? [var.ssm_jump_host_instance_type] : []
  ))
}

data "aws_ec2_instance_type" "node" {
  for_each      = local.node_instance_types
  instance_type = each.value

  lifecycle {
    postcondition {
      condition     = contains(self.supported_architectures, "arm64")
      error_message = "Instance type ${each.value} must support arm64 to run the Talos AMI."
    }
  }
}
