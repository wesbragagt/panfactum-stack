variable "operator_tunnel_security_group_ids" {
  description = "Security groups of SSM tunnel hosts (for example one NAT per AZ) allowed to reach the private Kubernetes and Talos APIs."
  type        = list(string)
  default     = []
}

resource "aws_vpc_security_group_ingress_rule" "operator_tunnel" {
  for_each = {
    for pair in setproduct(var.operator_tunnel_security_group_ids, ["kubernetes", "talos"]) :
    "${pair[0]}-${pair[1]}" => { security_group_id = pair[0], name = pair[1], port = pair[1] == "kubernetes" ? 6443 : 50000 }
  }

  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = each.value.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "${each.value.name} API from SSM tunnel hosts"
}
