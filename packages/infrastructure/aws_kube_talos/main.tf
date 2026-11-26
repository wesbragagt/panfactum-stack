// Live

terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "3.3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "3.5.0" }
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
  # Indexed by position; subnets are append-only once nodes exist
  control_plane_subnet_list = slice(var.control_plane_subnets, 0, min(var.control_plane_count, length(var.control_plane_subnets)))
  control_plane_node_count  = length(local.control_plane_subnet_list)
  bootstrap_subnet          = coalesce(var.bootstrap_control_plane, var.control_plane_subnets[0])
  bootstrap_index           = try(index(local.control_plane_subnet_list, local.bootstrap_subnet), 0)

  public_ip        = var.control_plane_public_ip_enabled ? aws_eip.api[0].public_ip : null
  api_host         = var.api_dns != null ? var.api_dns.name : coalesce(local.public_ip, try(var.control_plane_private_ips[0], null), "unset")
  cluster_endpoint = var.private_api_dns_name == null ? "https://${local.api_host}:6443" : "https://${var.private_api_dns_name}:6443"

  # Keep the Elastic IP valid in the API server cert so clients pinned to it survive a switch to the DNS name
  api_san_patch = yamlencode({
    apiVersion    = "v1alpha1", kind = "KubeAPIServerConfig"
    certExtraSANs = compact(distinct(concat([local.api_host, local.public_ip, var.private_api_dns_name, local.bootstrap_public_host], local.legacy_ssm_sans, var.kube_api_extra_sans)))
  })

  configured_talos_api_endpoint = (
    var.talos_access_transport == "bootstrap_public" ? local.bootstrap_public_host :
    var.talos_api_endpoint != "" ? var.talos_api_endpoint :
    var.talos_access_transport == "vpn" ? try(var.control_plane_private_ips[local.bootstrap_index], null) :
    "127.0.0.1"
  )
  talos_api_endpoint = var.talos_api_endpoint == null ? aws_eip_association.api[0].public_ip : local.configured_talos_api_endpoint

  talos_api_sans    = distinct(concat(compact([local.bootstrap_public_host]), local.legacy_ssm_sans, var.talos_api_extra_sans))
  talos_api_patches = local.bootstrap_public_enabled || length(local.talos_api_sans) > 0 ? [yamlencode({ machine = { certSANs = local.talos_api_sans } })] : []

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
  count  = local.control_plane_node_count
  vpc_id = var.vpc_id
  filter {
    name   = "tag:Name"
    values = [local.control_plane_subnet_list[count.index]]
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

resource "aws_vpc_security_group_ingress_rule" "talos_api_source" {
  for_each                     = var.talos_api_source_security_groups
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 50000
  to_port                      = 50000
  description                  = "Talos API"
}

resource "aws_vpc_security_group_ingress_rule" "kube_api_source" {
  for_each                     = var.kube_api_source_security_groups
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Kubernetes API"
}

# Nodes reach the endpoint through the Elastic IP, so traffic arrives from public addresses
resource "aws_vpc_security_group_ingress_rule" "kube_api_nodes" {
  count             = var.control_plane_public_ip_enabled ? 1 : 0
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "${aws_eip.api[0].public_ip}/32"
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
  count  = var.control_plane_public_ip_enabled ? 1 : 0
  domain = "vpc"

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-api"
  })
}

resource "aws_eip_association" "api" {
  count         = var.control_plane_public_ip_enabled ? 1 : 0
  allocation_id = aws_eip.api[0].id
  instance_id   = aws_instance.control_plane[local.bootstrap_index].id
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
  records = [aws_eip.api[0].public_ip]
}

###########################################################################
## Talos machine configuration
###########################################################################

locals {
  # SANs live in user data so the first boot's certs already validate through an SSM tunnel at 127.0.0.1
  control_plane_base_patches = concat([local.api_san_patch], local.talos_api_patches, local.cilium_config_patches, local.core_dns_config_patches, local.aws_control_plane_patches, var.control_plane_config_patches)
  control_plane_node_config = {
    apiVersion = "v1alpha1", kind = "KubeNodeConfig", labels = { "panfactum.com/class" = "controller" }
    taints     = { "node-role.kubernetes.io/control-plane" = { "$patch" = "delete" }, "controller" = "true:NoSchedule" }
  }
  oidc_config_patches = [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeServiceAccountConfig", issuer = { issuerURL = local.service_account_oidc_issuer_url } }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeAPIServerConfig", extraArgs = { "service-account-jwks-uri" = "${local.service_account_oidc_issuer_url}/keys.json" } })
  ]
}

data "talos_machine_configuration" "control_plane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = local.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false # With docs/examples the config exceeds the 16 KB EC2 user data limit
  examples           = false
  # The OIDC issuer rides in user data: a replaced controller that boots with the default issuer
  # rejects valid tokens and issues tokens every other API server rejects until kubelet refreshes them.
  config_patches = concat(local.control_plane_base_patches, local.oidc_config_patches, var.control_plane_workloads_enabled ? [yamlencode(local.control_plane_node_config)] : [])
}

# NOTE: Keep the bootstrap IP stable for Karpenter when there is no private API name.
resource "terraform_data" "worker_endpoint_ip" {
  count = var.private_api_dns_name == null ? 1 : 0
  input = aws_instance.control_plane[local.bootstrap_index].private_ip
}

locals {
  worker_cluster_endpoint = var.private_api_dns_name == null ? "https://${one(terraform_data.worker_endpoint_ip[*].output)}:6443" : local.cluster_endpoint
}

###########################################################################
## Nodes
###########################################################################

# User data gives nodes their config at boot, so they skip unauthenticated maintenance mode.
# Later config changes use the Talos API and upgrades use `talosctl upgrade`,
# so ami and user_data changes are ignored here.
resource "aws_instance" "control_plane" {
  count                       = local.control_plane_node_count
  ami                         = data.aws_ami.talos.id
  instance_type               = length(var.control_plane_instance_types) > 0 ? var.control_plane_instance_types[count.index] : var.control_plane_instance_type
  subnet_id                   = data.aws_subnet.control_plane[count.index].id
  private_ip                  = length(var.control_plane_private_ips) > 0 ? var.control_plane_private_ips[count.index] : null
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  associate_public_ip_address = var.control_plane_public_ip_enabled
  user_data                   = data.talos_machine_configuration.control_plane.machine_configuration
  iam_instance_profile        = var.controller_instance_profile != null ? var.controller_instance_profile : try(aws_iam_instance_profile.controller[0].name, null)

  depends_on = [terraform_data.pre_membership_snapshot]

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
    Name                                        = "${var.cluster_name}-control-plane-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })

  lifecycle {
    ignore_changes = [ami, user_data]

    # EC2 rejects user data over 16 KB raw; the OIDC patch must stay in it (see the config data source)
    precondition {
      condition     = length(data.talos_machine_configuration.control_plane.machine_configuration) <= 16384
      error_message = "Controller user data exceeds the 16 KB EC2 limit; move large patches to talos_machine_configuration_apply.control_plane."
    }
    # OpenTofu 1.8 variable validation cannot reference other variables
    precondition {
      condition     = var.control_plane_count <= length(var.control_plane_subnets)
      error_message = "control_plane_subnets needs one entry per control plane node."
    }
    precondition {
      condition     = contains(local.control_plane_subnet_list, local.bootstrap_subnet)
      error_message = "bootstrap_control_plane must be one of the first control_plane_count entries of control_plane_subnets."
    }
    precondition {
      condition     = local.control_plane_node_count == 1 || var.private_api_dns_name != null
      error_message = "control_plane_count above 1 requires private_api_dns_name."
    }
    precondition {
      condition     = length(var.control_plane_private_ips) == 0 || length(var.control_plane_private_ips) == local.control_plane_node_count
      error_message = "control_plane_private_ips needs one address per control plane node, or none."
    }
    precondition {
      condition     = var.talos_access_transport != "bootstrap_public" || (local.bootstrap_public_enabled && var.talos_api_endpoint == "")
      error_message = "bootstrap_public transport requires an enabled public load balancer and an empty talos_api_endpoint."
    }
    precondition {
      condition     = !local.bootstrap_public_enabled || (!var.control_plane_public_ip_enabled && var.private_api_dns_name != null)
      error_message = "bootstrap_public requires private controllers and private_api_dns_name."
    }
    precondition {
      condition     = var.talos_access_transport != "vpn" || var.talos_api_endpoint != "" || length(var.control_plane_private_ips) > 0
      error_message = "VPN access requires control_plane_private_ips or an explicit talos_api_endpoint."
    }
    precondition {
      condition     = var.control_plane_public_ip_enabled || (var.talos_api_endpoint != null && var.api_dns == null && (var.private_api_dns_name != null || length(var.control_plane_private_ips) > 0))
      error_message = "control_plane_public_ip_enabled = false requires talos_api_endpoint, private_api_dns_name or control_plane_private_ips, and no api_dns."
    }
  }
}

###########################################################################
## Bootstrap
###########################################################################

resource "talos_machine_configuration_apply" "control_plane" {
  count                       = local.control_plane_node_count
  client_configuration        = sensitive(local.client_configuration)
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  # Applied over the Talos API rather than user data, which is capped at 16 KB
  config_patches = local.backup_config_patches
  endpoint       = local.talos_api_endpoint
  node           = aws_instance.control_plane[count.index].private_ip

  # DNS and Talos ingress must exist before the first API call.
  depends_on = [
    aws_route53_record.api,
    aws_route53_record.private_api,
    aws_vpc_security_group_ingress_rule.talos_api,
    aws_vpc_security_group_ingress_rule.talos_api_source,
    aws_vpc_security_group_ingress_rule.operator_tunnel,
    aws_instance.ssm_jump_host,
    aws_vpc_security_group_ingress_rule.ssm_jump_host_talos,
    aws_lb_listener.bootstrap_public,
    aws_lb_target_group_attachment.bootstrap_public,
    aws_vpc_security_group_ingress_rule.bootstrap_public_operator,
    aws_vpc_security_group_ingress_rule.bootstrap_public_nodes,
    aws_vpc_security_group_egress_rule.bootstrap_public_nodes,
  ]

  # A replacement reuses the fixed IP, so node never changes; without this the new instance keeps
  # user data only and its API server rejects tokens from the shared OIDC issuer.
  lifecycle {
    replace_triggered_by = [aws_instance.control_plane[count.index].id]
  }
}

locals {
  bootstrap_node = aws_instance.control_plane[local.bootstrap_index].private_ip
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.control_plane]
  client_configuration = sensitive(local.client_configuration)
  endpoint             = local.talos_api_endpoint
  node                 = local.bootstrap_node

  lifecycle {
    # Bootstrap runs once. Re-running it on a replacement controller would start a second etcd cluster.
    ignore_changes = [node]
  }
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = sensitive(local.client_configuration)
  endpoint             = local.talos_api_endpoint
  node                 = local.bootstrap_node
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = sensitive(local.client_configuration)
  endpoints            = [local.talos_api_endpoint]
  nodes                = [var.talos_api_endpoint == null ? local.talos_api_endpoint : local.bootstrap_node]
}

moved {
  from = aws_eip.api
  to   = aws_eip.api[0]
}
moved {
  from = aws_eip_association.api
  to   = aws_eip_association.api[0]
}
