variable "operator_tunnel_security_group_id" {
  description = "Optional security group of SSM tunnel hosts allowed to reach the private Kubernetes and Talos APIs."
  type        = string
  default     = null
}

resource "aws_vpc_security_group_ingress_rule" "operator_tunnel" {
  for_each = var.operator_tunnel_security_group_id == null ? {} : {
    kubernetes = 6443
    talos      = 50000
  }

  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = var.operator_tunnel_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "${each.key} API from SSM tunnel hosts"
}
