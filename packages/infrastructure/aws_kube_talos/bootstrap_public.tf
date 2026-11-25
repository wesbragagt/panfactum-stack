locals {
  bootstrap_public_group_name        = "${var.cluster_name}-bootstrap-public"
  bootstrap_public_group_description = "Temporary public API access for ${var.cluster_name}"
  bootstrap_public_rule_description  = "Public bootstrap operator"
  bootstrap_public_allowed           = try(var.bootstrap_public.enabled, true)
  bootstrap_public_override_cidr     = try(var.bootstrap_public.operator_cidr, null)
  bootstrap_public_enabled = local.bootstrap_public_allowed && (
    var.talos_access_transport == "bootstrap_public" || local.bootstrap_public_override_cidr != null ||
    length(flatten(data.aws_security_groups.bootstrap_public_existing[*].ids)) > 0
  )
  bootstrap_public_ports = local.bootstrap_public_enabled ? tomap({ talos = 50000, kubernetes = 6443 }) : tomap({})
  bootstrap_public_host  = one(aws_lb.bootstrap_public[*].dns_name)
  bootstrap_public_existing_cidrs = toset([
    for rule in data.aws_vpc_security_group_rule.bootstrap_public_existing : rule.cidr_ipv4
    if !rule.is_egress && rule.ip_protocol == "tcp" && rule.from_port == rule.to_port &&
    contains(values(local.bootstrap_public_ports), rule.from_port) && rule.description == local.bootstrap_public_rule_description &&
    rule.cidr_ipv4 != null && rule.cidr_ipv4 != ""
  ])
}

# NOTE: The previous provider endpoint must stay reachable during the first private apply.
data "aws_security_groups" "bootstrap_public_existing" {
  count = local.bootstrap_public_allowed && local.bootstrap_public_override_cidr == null && !var.control_plane_public_ip_enabled && var.private_api_dns_name != null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "group-name"
    values = [local.bootstrap_public_group_name]
  }
  filter {
    name   = "description"
    values = [local.bootstrap_public_group_description]
  }
}

data "aws_vpc_security_group_rules" "bootstrap_public_existing" {
  for_each = toset(flatten(data.aws_security_groups.bootstrap_public_existing[*].ids))

  filter {
    name   = "group-id"
    values = [each.key]
  }
}

data "aws_vpc_security_group_rule" "bootstrap_public_existing" {
  for_each = toset(flatten([for rules in data.aws_vpc_security_group_rules.bootstrap_public_existing : rules.ids]))

  security_group_rule_id = each.key
}

data "external" "bootstrap_public_cidr" {
  count   = local.bootstrap_public_enabled && var.talos_access_transport == "bootstrap_public" && local.bootstrap_public_override_cidr == null && length(local.bootstrap_public_existing_cidrs) == 0 ? 1 : 0
  program = ["python3", "${path.module}/scripts/bootstrap_public_cidr.py"]

  lifecycle {
    postcondition {
      condition     = try(can(cidrnetmask(self.result.operator_cidr)) && endswith(self.result.operator_cidr, "/32") && self.result.operator_cidr != "0.0.0.0/32", false)
      error_message = "Public bootstrap could not detect a public IPv4 address for the runner."
    }
  }
}

data "aws_subnets" "bootstrap_public" {
  count = local.bootstrap_public_enabled ? 1 : 0
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
  count       = local.bootstrap_public_enabled ? 1 : 0
  name        = local.bootstrap_public_group_name
  description = local.bootstrap_public_group_description
  vpc_id      = var.vpc_id
  tags        = data.pf_aws_tags.tags.tags
}

resource "aws_vpc_security_group_ingress_rule" "bootstrap_public_operator" {
  for_each          = local.bootstrap_public_ports
  security_group_id = aws_security_group.bootstrap_public[0].id
  cidr_ipv4 = try(coalesce(
    local.bootstrap_public_override_cidr,
    try(one(local.bootstrap_public_existing_cidrs), null),
    one(data.external.bootstrap_public_cidr[*].result.operator_cidr),
  ), null)
  ip_protocol = "tcp"
  from_port   = each.value
  to_port     = each.value
  description = local.bootstrap_public_rule_description

  lifecycle {
    precondition {
      condition = local.bootstrap_public_override_cidr != null || (
        length(local.bootstrap_public_existing_cidrs) == 1
        ? try(cidrnetmask(one(local.bootstrap_public_existing_cidrs)) != "0.0.0.0", false)
        : length(data.external.bootstrap_public_cidr) == 1
      )
      error_message = "Public bootstrap needs a single valid IPv4 CIDR. Restore the public operator ingress rules or supply bootstrap_public.operator_cidr."
    }
  }
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
  count              = local.bootstrap_public_enabled ? 1 : 0
  name_prefix        = "talos-"
  internal           = false
  load_balancer_type = "network"
  subnets            = data.aws_subnets.bootstrap_public[0].ids
  security_groups    = [aws_security_group.bootstrap_public[0].id]
  tags               = merge(data.pf_aws_tags.tags.tags, { Name = local.bootstrap_public_group_name })
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
