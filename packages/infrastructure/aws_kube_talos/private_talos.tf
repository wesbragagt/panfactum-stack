locals {
  private_talos_listener_enabled = local.api_lb_enabled && local.stable_api_hostname != null
}

resource "aws_vpc_security_group_ingress_rule" "private_talos_source" {
  for_each                     = local.private_talos_listener_enabled ? var.talos_api_source_security_groups : {}
  security_group_id            = aws_security_group.api_lb[0].id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 50000
  to_port                      = 50000
  description                  = "Talos API through the internal load balancer"
}

resource "aws_vpc_security_group_ingress_rule" "private_talos_cidr" {
  for_each          = local.private_talos_listener_enabled ? toset(var.talos_api_allowed_cidrs) : toset([])
  security_group_id = aws_security_group.api_lb[0].id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 50000
  to_port           = 50000
  description       = "Talos API through the internal load balancer"
}

resource "aws_vpc_security_group_egress_rule" "private_talos_nodes" {
  count                        = local.private_talos_listener_enabled ? 1 : 0
  security_group_id            = aws_security_group.api_lb[0].id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 50000
  to_port                      = 50000
  description                  = "Talos API and health checks to controllers"
}

resource "aws_vpc_security_group_ingress_rule" "private_talos_nodes" {
  count                        = local.private_talos_listener_enabled ? 1 : 0
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.api_lb[0].id
  ip_protocol                  = "tcp"
  from_port                    = 50000
  to_port                      = 50000
  description                  = "Talos API from the internal load balancer"
}

resource "aws_lb_target_group" "private_talos" {
  count              = local.private_talos_listener_enabled ? 1 : 0
  name_prefix        = "talos-"
  port               = 50000
  protocol           = "TCP"
  target_type        = "instance"
  vpc_id             = var.vpc_id
  preserve_client_ip = false
  tags               = data.pf_aws_tags.tags.tags

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  # NOTE: A Talos health check failure must not remove a working Kubernetes endpoint from DNS.
  target_group_health {
    dns_failover {
      minimum_healthy_targets_count = "off"
    }
    unhealthy_state_routing {
      minimum_healthy_targets_count      = 1
      minimum_healthy_targets_percentage = "off"
    }
  }
}

resource "aws_lb_target_group_attachment" "private_talos" {
  count            = local.private_talos_listener_enabled ? local.control_plane_node_count : 0
  target_group_arn = aws_lb_target_group.private_talos[0].arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 50000
}

resource "aws_lb_listener" "private_talos" {
  count             = local.private_talos_listener_enabled ? 1 : 0
  load_balancer_arn = aws_lb.api[0].arn
  port              = 50000
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.private_talos[0].arn
  }
}
