terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.30.0"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  subnet_names = slice(var.subnets, 0, var.ha_enabled ? 2 : 1)

  # The VPC resolver sits at the network base plus two
  resolver = cidrhost(data.aws_vpc.vpc.cidr_block, 2)
  routes   = distinct(concat(var.advertised_routes, length(var.split_dns_domains) > 0 ? ["${local.resolver}/32"] : []))

  routers = {
    for name in local.subnet_names : name => {
      subnet_id = data.aws_subnet.router[name].id
      hostname  = "${var.name}-${replace(lower(name), "_", "-")}"
    }
  }
}

data "pf_aws_tags" "tags" {
  module = "aws_tailscale_subnet_router"
}

data "aws_region" "current" {}

data "aws_vpc" "vpc" {
  id = var.vpc_id
}

data "aws_subnet" "router" {
  for_each = toset(local.subnet_names)
  vpc_id   = var.vpc_id
  filter {
    name   = "tag:Name"
    values = [each.key]
  }
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

##########################################################################
## Tailscale credential
##########################################################################

# Routers exchange the OAuth secret for a fresh key at boot, so replacements never hit key expiry
resource "aws_ssm_parameter" "oauth_secret" {
  name  = "/${var.name}/tailscale-oauth-client-secret"
  type  = "SecureString"
  value = var.tailscale_oauth_client_secret
  tags  = data.pf_aws_tags.tags.tags
}

##########################################################################
## IAM
##########################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "router" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.oauth_secret.arn]
  }
}

resource "aws_iam_role" "router" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = data.pf_aws_tags.tags.tags
}

resource "aws_iam_role_policy" "router" {
  role   = aws_iam_role.router.id
  policy = data.aws_iam_policy_document.router.json
}

# SSM sessions let operators debug a router that never joined the tailnet
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.router.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "router" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.router.name
  tags        = data.pf_aws_tags.tags.tags
}

##########################################################################
## Network
##########################################################################

resource "aws_security_group" "router" {
  name_prefix = "${var.name}-"
  description = "Tailscale subnet routers"
  vpc_id      = var.vpc_id
  tags        = merge(data.pf_aws_tags.tags.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.router.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  security_group_id = aws_security_group.router.id
  description       = "Direct WireGuard connections from tailnet peers"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
}

##########################################################################
## Routers
##########################################################################

resource "aws_launch_template" "router" {
  for_each = local.routers

  name_prefix            = "${each.value.hostname}-"
  image_id               = data.aws_ssm_parameter.ami.insecure_value
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.router.arn
  }

  network_interfaces {
    associate_public_ip_address = var.public_ip_enabled
    security_groups             = [aws_security_group.router.id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # SNAT (the Tailscale default) sends return traffic to the router's own address,
  # so neither source/dest check changes nor VPC routes to 100.64.0.0/10 are needed.
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region    = data.aws_region.current.region
    parameter = aws_ssm_parameter.oauth_secret.name
    tag       = var.tailscale_tag
    routes    = join(",", local.routes)
    hostname  = each.value.hostname
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(data.pf_aws_tags.tags.tags, { Name = each.value.hostname })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(data.pf_aws_tags.tags.tags, { Name = each.value.hostname })
  }

  tags = data.pf_aws_tags.tags.tags

  # New AMIs apply only to replacement instances; refreshing both HA routers at once would drop the tailnet route
  lifecycle {
    ignore_changes = [image_id]
  }
}

# One ASG per AZ keeps each router pinned to its zone and replaces it if it fails
resource "aws_autoscaling_group" "router" {
  for_each = local.routers

  name_prefix         = "${each.value.hostname}-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [each.value.subnet_id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.router[each.key].id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = data.pf_aws_tags.tags.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}

##########################################################################
## Split DNS
##########################################################################

resource "tailscale_dns_split_nameservers" "vpc" {
  for_each    = toset(var.split_dns_domains)
  domain      = each.key
  nameservers = [local.resolver]
}
