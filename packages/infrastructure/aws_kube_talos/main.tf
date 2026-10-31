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
  api_host         = var.api_dns == null ? aws_eip.api.public_ip : var.api_dns.name
  cluster_endpoint = "https://${local.api_host}:6443"

  # Keep the Elastic IP valid in the API server cert so clients pinned to it survive a switch to the DNS name
  api_san_patch = yamlencode({
    apiVersion    = "v1alpha1", kind = "KubeAPIServerConfig"
    certExtraSANs = distinct([local.api_host, aws_eip.api.public_ip])
  })

  cilium_config_patches = var.cilium_enabled ? [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeFlannelCNIConfig", "$patch" = "delete" }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeProxyConfig", enabled = false })
  ] : []
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

# Operators reach the API directly; there is no load balancer in front of the single control plane
resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  for_each          = toset(var.kube_api_allowed_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "Kubernetes API"
}

# Nodes reach the endpoint through the Elastic IP, so traffic arrives from public addresses
resource "aws_vpc_security_group_ingress_rule" "kube_api_nodes" {
  for_each          = { for i, ip in concat([aws_eip.api.public_ip], aws_instance.worker[*].public_ip) : tostring(i) => ip }
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "${each.value}/32"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "Kubernetes API from cluster nodes"
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
}

###########################################################################
## Kubernetes API endpoint
###########################################################################

# Allocated before the instance so the address can go into the machine config
# (and the API server cert SANs); associated after the instance exists.
resource "aws_eip" "api" {
  domain = "vpc"

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-api"
  })
}

resource "aws_eip_association" "api" {
  allocation_id = aws_eip.api.id
  instance_id   = aws_instance.control_plane[0].id
}

resource "aws_route53_record" "api" {
  count   = var.api_dns == null ? 0 : 1
  zone_id = var.api_dns.zone_id
  name    = var.api_dns.name
  type    = "A"
  ttl     = 300
  records = [aws_eip.api.public_ip]
}

###########################################################################
## Talos machine configuration
###########################################################################

data "talos_machine_configuration" "control_plane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = var.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false # With docs/examples the config exceeds the 16 KB EC2 user data limit
  examples           = false
  config_patches     = local.cilium_config_patches
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = var.machine_secrets
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

  instance_market_options {
    market_type = "spot"

    spot_options {
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
    }
  }

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
  client_configuration        = var.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  # Applied over the Talos API rather than user data, which is capped at 16 KB
  config_patches = concat(local.backup_config_patches, [local.api_san_patch])
  endpoint       = aws_eip_association.api.public_ip
  node           = aws_instance.control_plane[count.index].private_ip

  # Nodes resolve the cluster endpoint during the apply, so the record must exist first
  depends_on = [aws_route53_record.api]
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = var.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = aws_instance.worker[count.index].public_ip
  node                        = aws_instance.worker[count.index].private_ip
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.control_plane]
  client_configuration = var.client_configuration
  endpoint             = aws_eip_association.api.public_ip
  node                 = aws_instance.control_plane[0].private_ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = var.client_configuration
  endpoint             = aws_eip_association.api.public_ip
  node                 = aws_instance.control_plane[0].private_ip
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = var.client_configuration
  endpoints            = [aws_eip_association.api.public_ip]
  nodes                = [aws_eip_association.api.public_ip]
}
