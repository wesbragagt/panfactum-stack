// Live

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  cluster_endpoint = "https://${aws_lb.api.dns_name}:6443"
}

data "pf_aws_tags" "tags" {
  module = "aws_kube_talos"
}

data "aws_region" "current" {}

# Official Sidero Labs AMIs; same lookup as siderolabs/contrib examples/terraform/aws
data "aws_ami" "talos" {
  owners      = ["540036508848"]
  most_recent = true

  filter {
    name   = "name"
    values = ["talos-${var.talos_version}-${data.aws_region.current.region}-arm64"]
  }
}

data "aws_subnets" "control_plane" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "tag:Name"
    values = var.control_plane_subnets
  }
}

data "aws_subnets" "worker" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "tag:Name"
    values = var.worker_subnets
  }
}

###########################################################################
## Security groups
###########################################################################

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "Talos nodes for ${var.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-nodes"
  })
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "All intra-cluster traffic"
}

resource "aws_vpc_security_group_ingress_rule" "talos_api" {
  for_each          = toset(var.talos_api_allowed_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 50000
  to_port           = 50000
  description       = "Talos API"
}

resource "aws_vpc_security_group_ingress_rule" "kube_api_from_lb" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.lb.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Kubernetes API from the NLB (traffic and health checks)"
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
}

resource "aws_security_group" "lb" {
  name        = "${var.cluster_name}-api-lb"
  description = "Kubernetes API NLB for ${var.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-api-lb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "lb_operators" {
  for_each          = toset(var.kube_api_allowed_cidrs)
  security_group_id = aws_security_group.lb.id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "Kubernetes API"
}

# The NLB is internet-facing, so nodes reach the cluster endpoint from their public IPs
resource "aws_vpc_security_group_ingress_rule" "lb_nodes" {
  for_each          = { for i, ip in concat(aws_instance.control_plane[*].public_ip, aws_instance.worker[*].public_ip) : tostring(i) => ip }
  security_group_id = aws_security_group.lb.id
  cidr_ipv4         = "${each.value}/32"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "Kubernetes API from cluster nodes"
}

resource "aws_vpc_security_group_egress_rule" "lb_to_nodes" {
  security_group_id            = aws_security_group.lb.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Forward to control plane nodes"
}

###########################################################################
## Kubernetes API load balancer
###########################################################################

resource "aws_lb" "api" {
  name                             = "${var.cluster_name}-api"
  load_balancer_type               = "network"
  internal                         = false
  subnets                          = data.aws_subnets.control_plane.ids
  security_groups                  = [aws_security_group.lb.id]
  enable_cross_zone_load_balancing = true

  tags = data.pf_aws_tags.tags.tags
}

resource "aws_lb_target_group" "api" {
  name        = "${var.cluster_name}-api"
  port        = 6443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  # With client IP preservation, a control plane node cannot reach itself through the NLB (hairpin)
  preserve_client_ip = false

  health_check {
    protocol = "TCP"
    port     = "6443"
  }

  tags = data.pf_aws_tags.tags.tags
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = data.pf_aws_tags.tags.tags
}

resource "aws_lb_target_group_attachment" "api" {
  count            = var.control_plane_count
  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 6443
}

###########################################################################
## Talos machine configuration
###########################################################################

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "control_plane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false # With docs/examples the config exceeds the 16 KB EC2 user data limit
  examples           = false
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false
  examples           = false
}

###########################################################################
## Nodes
###########################################################################

# Nodes read their initial config from user data via IMDS, so they never sit in
# unauthenticated maintenance mode. Later config changes go through the Talos API
# (talos_machine_configuration_apply) and OS upgrades through `talosctl upgrade`,
# so ami and user_data changes are ignored here.
resource "aws_instance" "control_plane" {
  count                       = var.control_plane_count
  ami                         = data.aws_ami.talos.id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = element(sort(data.aws_subnets.control_plane.ids), count.index)
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  associate_public_ip_address = true
  user_data                   = data.talos_machine_configuration.control_plane.machine_configuration

  # Hop limit 1 keeps pods (and the machine config in user data) away from IMDS
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-control-plane-${count.index}"
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_instance" "worker" {
  count                       = var.worker_count
  ami                         = data.aws_ami.talos.id
  instance_type               = var.worker_instance_type
  subnet_id                   = element(sort(data.aws_subnets.worker.ids), count.index)
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  associate_public_ip_address = true
  user_data                   = data.talos_machine_configuration.worker.machine_configuration

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-worker-${count.index}"
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

###########################################################################
## Bootstrap
###########################################################################

resource "talos_machine_configuration_apply" "control_plane" {
  count                       = var.control_plane_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  # Applied over the Talos API rather than user data, which is capped at 16 KB
  config_patches = local.backup_config_patches
  endpoint       = aws_instance.control_plane[count.index].public_ip
  node           = aws_instance.control_plane[count.index].private_ip
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = aws_instance.worker[count.index].public_ip
  node                        = aws_instance.worker[count.index].private_ip
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.control_plane]
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = aws_instance.control_plane[0].public_ip
  node                 = aws_instance.control_plane[0].private_ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = aws_instance.control_plane[0].public_ip
  node                 = aws_instance.control_plane[0].private_ip
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = aws_instance.control_plane[*].public_ip
  nodes                = aws_instance.control_plane[*].public_ip
}
