locals {
  bootstrap_public_ports = var.bootstrap_public == null ? tomap({}) : tomap({ talos = 50000, kubernetes = 6443 })
  bootstrap_public_host  = one(aws_lb.bootstrap_public[*].dns_name)
}

data "aws_subnets" "bootstrap_public" {
  count = var.bootstrap_public == null ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "availability-zone"
    values = [data.aws_subnet.control_plane[local.bootstrap_index].availability_zone]
  }
  tags = { "panfactum.com/type" = "public" }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 1
      error_message = "Public bootstrap requires one Panfactum public subnet in the bootstrap controller's availability zone."
    }
  }
}

resource "aws_security_group" "bootstrap_public" {
  count       = var.bootstrap_public == null ? 0 : 1
  name        = "${var.cluster_name}-bootstrap-public"
  description = "Temporary public API access for ${var.cluster_name}"
  vpc_id      = var.vpc_id
  tags        = data.pf_aws_tags.tags.tags
}

resource "aws_vpc_security_group_ingress_rule" "bootstrap_public_operator" {
  for_each          = local.bootstrap_public_ports
  security_group_id = aws_security_group.bootstrap_public[0].id
  cidr_ipv4         = var.bootstrap_public.operator_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Public bootstrap operator"
}

resource "aws_vpc_security_group_egress_rule" "bootstrap_public_nodes" {
  for_each                     = local.bootstrap_public_ports
  security_group_id            = aws_security_group.bootstrap_public[0].id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "API traffic and health checks to controllers"
}

resource "aws_vpc_security_group_ingress_rule" "bootstrap_public_nodes" {
  for_each                     = local.bootstrap_public_ports
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.bootstrap_public[0].id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "API traffic and health checks from the bootstrap load balancer"
}

resource "aws_lb" "bootstrap_public" {
  count              = var.bootstrap_public == null ? 0 : 1
  name_prefix        = "talos-"
  internal           = false
  load_balancer_type = "network"
  subnets            = data.aws_subnets.bootstrap_public[0].ids
  security_groups    = [aws_security_group.bootstrap_public[0].id]
  tags               = merge(data.pf_aws_tags.tags.tags, { Name = "${var.cluster_name}-bootstrap-public" })
}

resource "aws_lb_target_group" "bootstrap_public" {
  for_each           = local.bootstrap_public_ports
  name_prefix        = "talos-"
  port               = each.value
  protocol           = "TCP"
  target_type        = "ip"
  preserve_client_ip = false
  vpc_id             = var.vpc_id
  tags               = data.pf_aws_tags.tags.tags

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}

resource "aws_lb_listener" "bootstrap_public" {
  for_each          = local.bootstrap_public_ports
  load_balancer_arn = aws_lb.bootstrap_public[0].arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bootstrap_public[each.key].arn
  }
}

resource "aws_lb_target_group_attachment" "bootstrap_public" {
  for_each         = local.bootstrap_public_ports
  target_group_arn = aws_lb_target_group.bootstrap_public[each.key].arn
  target_id        = local.bootstrap_node
  port             = each.value
}
