# Positions at or above the desired count are about to be destroyed. Count is 0 when none can
# exist (5 is the maximum), so normal plans make no EC2 call and the filter never gets an empty list.
data "aws_instances" "removed_control_plane" {
  count = local.control_plane_node_count < 5 ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [for k in range(local.control_plane_node_count, 5) : "${var.cluster_name}-control-plane-${k}"]
  }
  instance_state_names = ["pending", "running", "stopping", "stopped"]
}

locals {
  removed_control_plane_ips = try(data.aws_instances.removed_control_plane[0].private_ips, [])
}

# Destroying a voting etcd member loses quorum, so the plan fails (also when talosctl cannot
# list members) instead of relying on the operator remembering `etcd leave`.
data "external" "etcd_members" {
  count   = length(local.removed_control_plane_ips) > 0 ? 1 : 0
  program = ["python3", "${path.module}/scripts/etcd_members.py"]
  # Inputs come from variables and data sources, not aws_instance, so the read happens at plan
  # time even when the same plan changes a controller.
  query = {
    endpoint = var.talos_api_endpoint == null ? aws_eip.api[0].public_ip : local.configured_talos_api_endpoint
    node     = data.aws_instances.existing_control_plane.private_ips[0]
    ca       = local.client_configuration.ca_certificate
    crt      = local.client_configuration.client_certificate
    key      = local.client_configuration.client_key
  }

  lifecycle {
    postcondition {
      condition     = length(setintersection(toset(local.removed_control_plane_ips), toset(split(",", nonsensitive(self.result.member_ips))))) == 0
      error_message = "Controllers being removed are still etcd members: ${join(", ", sort(tolist(setintersection(toset(local.removed_control_plane_ips), toset(split(",", nonsensitive(self.result.member_ips)))))))}. For each, run `talosctl -n <ip> etcd leave`, then `kubectl delete node <node>` (README \"Shrink 5 to 3 to 1\"), and plan again."
    }
  }
}
