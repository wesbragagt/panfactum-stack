// Live

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "2.3.5"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  api_host         = var.api_dns == null ? aws_eip.api.public_ip : var.api_dns.name
  cluster_endpoint = var.private_api_dns_name == null ? "https://${local.api_host}:6443" : "https://${var.private_api_dns_name}:6443"

  # Keep the Elastic IP valid in the API server cert so clients pinned to it survive a switch to the DNS name
  api_san_patch = yamlencode({
    apiVersion    = "v1alpha1", kind = "KubeAPIServerConfig"
    certExtraSANs = compact(distinct([local.api_host, aws_eip.api.public_ip, var.private_api_dns_name, "127.0.0.1"]))
  })

  # Callers behind the SSM tunnel reach the Talos API on 127.0.0.1; others keep the Elastic IP
  talos_api_endpoint = coalesce(var.talos_api_endpoint, aws_eip_association.api.public_ip)

  # The SSM tunnel connects on 127.0.0.1, so the Talos API cert must be valid there (Talos 1.14 has no typed doc for this)
  talos_api_san_patch = yamlencode({ machine = { certSANs = ["127.0.0.1"] } })

  cilium_config_patches = var.cilium_enabled ? [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeFlannelCNIConfig", "$patch" = "delete" }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeProxyConfig", enabled = false })
  ] : []

  # Talos 1.14 rejects the legacy .cluster.coreDNS patch; KubeCoreDNSConfig is the supported switch.
  core_dns_config_patches = var.core_dns_enabled ? [] : [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeCoreDNSConfig", enabled = false })
  ]
}

data "pf_aws_tags" "tags" {
  module = "aws_kube_talos"
}

data "aws_region" "current" {}

# Official Sidero Labs AMIs; same lookup as siderolabs/contrib examples/terraform/aws
data "aws_ami" "talos" {
  owners      = var.ami_id == null ? ["540036508848"] : null
  most_recent = var.ami_id == null

  filter {
    name   = var.ami_id == null ? "name" : "image-id"
    values = var.ami_id == null ? ["talos-${var.talos_version}-${data.aws_region.current.region}-arm64"] : [var.ami_id]
  }
}

# One lookup per node so placement follows control_plane_subnets order, not subnet IDs
data "aws_subnet" "control_plane" {
  count  = var.control_plane_count
  vpc_id = var.vpc_id
  filter {
    name   = "tag:Name"
    values = [var.control_plane_subnets[count.index]]
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
  for_each          = { "0" = aws_eip.api.public_ip }
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

resource "aws_route53_zone" "private_api" {
  count = var.private_api_dns_name == null ? 0 : 1
  name  = join(".", slice(split(".", var.private_api_dns_name), 1, length(split(".", var.private_api_dns_name))))

  vpc {
    vpc_id = var.vpc_id
  }

  tags = data.pf_aws_tags.tags.tags
}

# Clients and kubelets try each address; KubePrism load-balances after nodes join
resource "aws_route53_record" "private_api" {
  count   = var.private_api_dns_name == null ? 0 : 1
  zone_id = aws_route53_zone.private_api[0].zone_id
  name    = var.private_api_dns_name
  type    = "A"
  ttl     = 30
  records = aws_instance.control_plane[*].private_ip
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
  machine_secrets    = local.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false # With docs/examples the config exceeds the 16 KB EC2 user data limit
  examples           = false
  # SANs live in user data so the first boot's certs already validate through an SSM tunnel at 127.0.0.1
  config_patches = concat([local.api_san_patch, local.talos_api_san_patch], var.aws_node_config_enabled ? concat(local.cilium_config_patches, local.core_dns_config_patches, local.aws_control_plane_patches, var.control_plane_config_patches, var.control_plane_workloads_enabled ? [yamlencode({ apiVersion = "v1alpha1", kind = "KubeNodeConfig", labels = { "panfactum.com/class" = "controller" }, taints = { "node-role.kubernetes.io/control-plane" = { "$patch" = "delete" } } })] : []) : concat(local.cilium_config_patches, local.core_dns_config_patches, var.control_plane_config_patches, var.control_plane_workloads_enabled ? [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeNodeConfig", taints = { "node-role.kubernetes.io/control-plane" = null } })
  ] : []))
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.private_api_dns_name == null ? "https://${aws_instance.control_plane[0].private_ip}:6443" : local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = local.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false
  examples           = false
  config_patches     = var.aws_node_config_enabled ? concat(local.aws_worker_patches, [yamlencode({ apiVersion = "v1alpha1", kind = "KubeNodeConfig", registerWithFQDN = true, labels = { "panfactum.com/class" = "worker", "node.kubernetes.io/lifecycle" = "spot" }, taints = { "spot" = "true:NoSchedule" } })], var.worker_config_patches) : var.worker_config_patches
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
  instance_type               = length(var.control_plane_instance_types) > 0 ? var.control_plane_instance_types[count.index] : var.control_plane_instance_type
  subnet_id                   = data.aws_subnet.control_plane[count.index].id
  private_ip                  = length(var.control_plane_private_ips) > 0 ? var.control_plane_private_ips[count.index] : null
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  associate_public_ip_address = true
  user_data                   = data.talos_machine_configuration.control_plane.machine_configuration

  # A stopped Spot node resumes with the same disk and IP, so it rejoins etcd without replacement
  dynamic "instance_market_options" {
    for_each = var.control_plane_spot_enabled ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

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

    # OpenTofu 1.8 variable validation cannot reference other variables
    precondition {
      condition     = var.control_plane_count <= length(var.control_plane_subnets)
      error_message = "control_plane_subnets needs one entry per control plane node."
    }
    precondition {
      condition     = var.control_plane_count == 1 || var.private_api_dns_name != null
      error_message = "control_plane_count = 3 requires private_api_dns_name."
    }
    precondition {
      condition     = length(var.control_plane_private_ips) == 0 || length(var.control_plane_private_ips) == var.control_plane_count
      error_message = "control_plane_private_ips needs one address per control plane node, or none."
    }
  }
}

resource "aws_launch_template" "worker" {
  name_prefix   = "${var.cluster_name}-worker-"
  image_id      = data.aws_ami.talos.id
  instance_type = var.worker_instance_type
  user_data     = base64encode(data.talos_machine_configuration.worker.machine_configuration)

  dynamic "iam_instance_profile" {
    for_each = var.worker_instance_profile_arn == null ? [] : [var.worker_instance_profile_arn]
    content { arn = iam_instance_profile.value }
  }

  network_interfaces {
    associate_public_ip_address = var.worker_public_ip_enabled
    security_groups             = [aws_security_group.nodes.id]
  }

  # A mixed instances policy owns the Spot request when fallback types are set.
  dynamic "instance_market_options" {
    for_each = length(var.worker_instance_types) > 0 ? [] : [1]
    content {
      market_type = "spot"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = data.aws_ami.talos.root_device_name
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(data.pf_aws_tags.tags.tags, {
      Name = "${var.cluster_name}-worker"
    })
  }

  tags = data.pf_aws_tags.tags.tags
}

resource "aws_autoscaling_group" "worker" {
  suspended_processes = var.worker_suspended_processes
  capacity_rebalance  = var.worker_capacity_rebalance
  dynamic "tag" {
    for_each = var.aws_node_config_enabled ? [var.cluster_name] : []
    content {
      key                 = "kubernetes.io/cluster/${tag.value}"
      value               = "owned"
      propagate_at_launch = true
    }
  }
  name_prefix         = "${var.cluster_name}-worker-"
  min_size            = var.worker_count
  max_size            = var.worker_count
  desired_capacity    = var.worker_count
  vpc_zone_identifier = data.aws_subnets.worker.ids
  health_check_type   = "EC2"

  dynamic "launch_template" {
    for_each = length(var.worker_instance_types) > 0 ? [] : [1]
    content {
      id      = aws_launch_template.worker.id
      version = aws_launch_template.worker.latest_version
    }
  }

  # Spot capacity for one type can run out in a zone whose EBS volumes pin stateful pods.
  dynamic "mixed_instances_policy" {
    for_each = length(var.worker_instance_types) > 0 ? [1] : []
    content {
      instances_distribution {
        on_demand_base_capacity                  = 0
        on_demand_percentage_above_base_capacity = 0
        spot_allocation_strategy                 = "price-capacity-optimized"
      }
      launch_template {
        launch_template_specification {
          launch_template_id = aws_launch_template.worker.id
          version            = aws_launch_template.worker.latest_version
        }
        dynamic "override" {
          for_each = var.worker_instance_types
          content {
            instance_type = override.value
          }
        }
      }
    }
  }

  # Workers join over the private API address, not their changing public IPs.
  depends_on = [talos_machine_bootstrap.this]
}

data "aws_subnets" "worker_on_demand" {
  count = length(var.on_demand_worker_subnets) > 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "tag:Name"
    values = var.on_demand_worker_subnets
  }
}

# One on-demand worker per listed subnet, so zones holding EBS-backed stateful pods keep a node through Spot reclaims.
resource "aws_autoscaling_group" "worker_on_demand" {
  count               = length(var.on_demand_worker_subnets) > 0 ? 1 : 0
  name_prefix         = "${var.cluster_name}-worker-od-"
  min_size            = length(var.on_demand_worker_subnets)
  max_size            = length(var.on_demand_worker_subnets)
  desired_capacity    = length(var.on_demand_worker_subnets)
  vpc_zone_identifier = data.aws_subnets.worker_on_demand[0].ids
  health_check_type   = "EC2"

  # Without fallback types the launch template requests Spot; override to on-demand here.
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = length(var.on_demand_worker_subnets)
      on_demand_percentage_above_base_capacity = 100
    }
    launch_template {
      launch_template_specification {
        launch_template_id = var.aws_node_config_enabled ? aws_launch_template.worker_on_demand[0].id : aws_launch_template.worker.id
        version            = var.aws_node_config_enabled ? aws_launch_template.worker_on_demand[0].latest_version : aws_launch_template.worker.latest_version
      }
      override {
        instance_type = var.worker_instance_type
      }
    }
  }

  depends_on = [talos_machine_bootstrap.this]
}

###########################################################################
## Bootstrap
###########################################################################

resource "talos_machine_configuration_apply" "control_plane" {
  count                       = var.control_plane_count
  client_configuration        = sensitive(local.client_configuration)
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  # Applied over the Talos API rather than user data, which is capped at 16 KB
  config_patches = concat(local.backup_config_patches, [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeServiceAccountConfig", issuer = { issuerURL = local.canary_oidc_issuer_url } }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeAPIServerConfig", extraArgs = { "service-account-jwks-uri" = "${local.canary_oidc_issuer_url}/keys.json" } })
  ])
  endpoint = local.talos_api_endpoint
  node     = aws_instance.control_plane[count.index].private_ip

  # Nodes resolve the cluster endpoint during the apply, so the record must exist first
  # On first bootstrap through a tunnel, the tunnel hosts need ingress before the first call
  depends_on = [aws_route53_record.api, aws_route53_record.private_api, aws_vpc_security_group_ingress_rule.operator_tunnel]
}


resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.control_plane]
  client_configuration = sensitive(local.client_configuration)
  endpoint             = local.talos_api_endpoint
  node                 = aws_instance.control_plane[0].private_ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = sensitive(local.client_configuration)
  endpoint             = local.talos_api_endpoint
  node                 = aws_instance.control_plane[0].private_ip
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = sensitive(local.client_configuration)
  endpoints            = [local.talos_api_endpoint]
  nodes                = [var.talos_api_endpoint == null ? aws_eip_association.api.public_ip : aws_instance.control_plane[0].private_ip]
}
