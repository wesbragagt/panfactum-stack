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
  # The NLB fronts the private API name, so callers without one get none
  api_lb_enabled = var.api_load_balancer_enabled && var.private_api_dns_name != null
  # Indexed by position; entries are append-only once nodes exist
  control_plane_node_count = length(var.control_plane)
  control_plane_ip_set     = anytrue([for n in var.control_plane : n.private_ip != null])

  public_ip        = var.control_plane_public_ip_enabled ? aws_eip.api[0].public_ip : null
  api_host         = var.api_dns != null ? var.api_dns.name : coalesce(local.public_ip, var.control_plane[0].private_ip, "unset")
  cluster_endpoint = var.private_api_dns_name == null ? "https://${local.api_host}:6443" : "https://${var.private_api_dns_name}:6443"

  # Keep the Elastic IP valid in the API server cert so clients pinned to it survive a switch to the DNS name
  api_san_patch = yamlencode({
    apiVersion    = "v1alpha1", kind = "KubeAPIServerConfig"
    certExtraSANs = compact(distinct(concat([local.api_host, local.public_ip, var.private_api_dns_name, local.bootstrap_public_nlb_host], local.legacy_ssm_sans, var.kube_api_extra_sans)))
  })

  configured_talos_api_endpoint = (
    var.talos_access_transport == "bootstrap_public" ? local.bootstrap_public_host :
    var.talos_api_endpoint != "" ? var.talos_api_endpoint :
    var.talos_access_transport == "vpn" ? (local.stable_api_hostname != null ? local.stable_api_hostname : var.control_plane[0].private_ip) :
    "127.0.0.1"
  )
  talos_api_endpoint = var.talos_api_endpoint == null ? aws_eip_association.api[0].public_ip : local.configured_talos_api_endpoint

  talos_api_sans    = distinct(concat(compact([local.bootstrap_public_nlb_host, local.stable_api_hostname]), local.legacy_ssm_sans, var.talos_api_extra_sans))
  talos_api_patches = local.bootstrap_public_enabled || length(local.talos_api_sans) > 0 ? [yamlencode({ machine = { certSANs = local.talos_api_sans } })] : []

  # Panfactum kube_cilium and kube_core_dns own networking and DNS, so Talos never deploys Flannel, kube-proxy or CoreDNS.
  # Talos 1.14 rejects the legacy .cluster.coreDNS patch; KubeCoreDNSConfig is the supported switch.
  networking_disable_patches = [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeFlannelCNIConfig", "$patch" = "delete" }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeProxyConfig", enabled = false }),
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

# One lookup per node so placement follows control_plane order, not subnet IDs
data "aws_subnet" "control_plane" {
  count  = local.control_plane_node_count
  vpc_id = var.vpc_id
  filter {
    name   = "tag:Name"
    values = [var.control_plane[count.index].subnet]
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

resource "aws_route53_record" "private_api" {
  count   = var.private_api_dns_name == null ? 0 : 1
  zone_id = aws_route53_zone.private_api[0].zone_id
  name    = var.private_api_dns_name
  type    = "A"
  ttl     = local.api_lb_enabled ? null : 30
  records = local.api_lb_enabled ? null : aws_instance.control_plane[*].private_ip

  dynamic "alias" {
    for_each = local.api_lb_enabled ? [1] : []
    content {
      name                   = aws_lb.api[0].dns_name
      zone_id                = aws_lb.api[0].zone_id
      evaluate_target_health = local.stable_api_hostname == null
    }
  }
}

# The NLB health-checks /readyz, so clients skip a controller that accepts TCP but is not ready.
resource "aws_security_group" "api_lb" {
  count       = local.api_lb_enabled ? 1 : 0
  name        = "${var.cluster_name}-api-lb"
  description = "Kubernetes API load balancer for ${var.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-api-lb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "api_lb_nodes" {
  count                        = local.api_lb_enabled ? 1 : 0
  security_group_id            = aws_security_group.api_lb[0].id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Kubernetes API from cluster nodes"
}

resource "aws_vpc_security_group_ingress_rule" "api_lb_source" {
  for_each                     = local.api_lb_enabled ? var.kube_api_source_security_groups : {}
  security_group_id            = aws_security_group.api_lb[0].id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Kubernetes API"
}

resource "aws_vpc_security_group_ingress_rule" "api_lb_cidr" {
  for_each          = local.api_lb_enabled ? toset(var.kube_api_allowed_cidrs) : toset([])
  security_group_id = aws_security_group.api_lb[0].id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "Kubernetes API"
}

resource "aws_vpc_security_group_egress_rule" "api_lb_nodes" {
  count                        = local.api_lb_enabled ? 1 : 0
  security_group_id            = aws_security_group.api_lb[0].id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Kubernetes API and health checks to controllers"
}

# With preserve_client_ip off, traffic and health checks reach nodes from the NLB's security group
resource "aws_vpc_security_group_ingress_rule" "kube_api_lb" {
  count                        = local.api_lb_enabled ? 1 : 0
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.api_lb[0].id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Kubernetes API from the load balancer"
}

resource "aws_lb" "api" {
  count                            = local.api_lb_enabled ? 1 : 0
  name                             = "${var.cluster_name}-api"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = data.aws_subnet.control_plane[*].id
  security_groups                  = [aws_security_group.api_lb[0].id]
  enable_cross_zone_load_balancing = true

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = "${var.cluster_name}-api"
  })
}

resource "aws_lb_target_group" "api" {
  count                  = local.api_lb_enabled ? 1 : 0
  name                   = "${var.cluster_name}-api"
  port                   = 6443
  protocol               = "TCP"
  target_type            = "instance"
  vpc_id                 = var.vpc_id
  preserve_client_ip     = false
  connection_termination = true

  # Drill on 2026-11-24: a 10s interval left an unready API server in rotation for about 25s
  health_check {
    protocol            = "HTTPS"
    path                = "/readyz"
    port                = "6443"
    interval            = 5
    timeout             = 4
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = data.pf_aws_tags.tags.tags
}

resource "aws_lb_target_group_attachment" "api" {
  count            = local.api_lb_enabled ? local.control_plane_node_count : 0
  target_group_arn = aws_lb_target_group.api[0].arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 6443
}

resource "aws_lb_listener" "api" {
  count             = local.api_lb_enabled ? 1 : 0
  load_balancer_arn = aws_lb.api[0].arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
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
  # NOTE: The first boot needs the API SAN before the provider can apply machine configuration.
  control_plane_base_patches = concat(
    [local.api_san_patch],
    local.talos_api_patches,
    local.networking_disable_patches,
    local.aws_control_plane_patches,
    var.panfactum_scheduler_enabled ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeSchedulerConfig"
      image      = "registry.k8s.io/kube-scheduler:v${var.kube_version}"
      config = {
        profiles = [
          { schedulerName = "default-scheduler" },
          {
            schedulerName = "panfactum"
            plugins = {
              score = {
                enabled = [{ name = "NodeResourcesFit", weight = 2 }]
              }
            }
            pluginConfig = [{
              name = "NodeResourcesFit"
              args = {
                scoringStrategy = {
                  type = "MostAllocated"
                  resources = [
                    { name = "cpu", weight = 1 },
                    { name = "memory", weight = 1 },
                  ]
                }
              }
            }]
          },
        ]
      }
    })] : [],
    var.control_plane_config_patches,
  )
  control_plane_node_config = {
    apiVersion = "v1alpha1", kind = "KubeNodeConfig", labels = { "panfactum.com/class" = "controller", "node.kubernetes.io/lifecycle" = "on-demand", "node.kubernetes.io/role" = "controller" }
    taints     = merge({ "node-role.kubernetes.io/control-plane" = { "$patch" = "delete" } }, var.bootstrap_mode_enabled ? {} : { "controller" = "true:NoSchedule" })
  }
  # A separate document leaves the default patch list unchanged and applies even without workloads.
  fqdn_patches = var.control_plane_register_with_fqdn ? [yamlencode({ apiVersion = "v1alpha1", kind = "KubeNodeConfig", registerWithFQDN = true })] : []
  oidc_config_patches = [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeServiceAccountConfig", issuer = { issuerURL = local.service_account_oidc_issuer_url } }),
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeAPIServerConfig", extraArgs = { "service-account-jwks-uri" = "${local.service_account_oidc_issuer_url}/keys.json" } })
  ]
  control_plane_patches = concat(local.control_plane_base_patches, local.oidc_config_patches, var.control_plane_workloads_enabled || var.bootstrap_mode_enabled ? [yamlencode(local.control_plane_node_config)] : [], local.fqdn_patches)
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
  config_patches = local.control_plane_patches
}

data "talos_machine_configuration" "control_plane_runtime" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = local.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kube_version
  docs               = false
  examples           = false
  # NOTE: Stock AMIs lack the ecr-credential-provider binary until talos_machine installs the
  # Factory image, so the provider config stays out of boot user data.
  config_patches = concat(local.control_plane_patches, local.backup_config_patches, [
    yamlencode({ apiVersion = "v1alpha1", kind = "KubeCredentialProviderConfig", configuration = {
      apiVersion = "kubelet.config.k8s.io/v1", kind = "CredentialProviderConfig", providers = [{
        name = "ecr-credential-provider", apiVersion = "credentialprovider.kubelet.k8s.io/v1", defaultCacheDuration = "12h", matchImages = ["*.dkr.ecr.*.amazonaws.com"]
      }]
    } }),
  ])
}

# Workers reach the bootstrap controller IP only without a private API name. The indirection
# keeps worker configs free of aws_instance references, so adding controllers does not defer them.
resource "terraform_data" "worker_endpoint_ip" {
  count = var.private_api_dns_name == null ? 1 : 0
  input = aws_instance.control_plane[0].private_ip
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
  instance_type               = var.control_plane[count.index].instance_type
  subnet_id                   = data.aws_subnet.control_plane[count.index].id
  private_ip                  = var.control_plane[count.index].private_ip
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
      error_message = "Controller user data exceeds the 16 KB EC2 limit; keep large patches in the runtime machine configuration."
    }
    # OpenTofu 1.8 variable validation cannot reference other variables
    precondition {
      condition     = local.control_plane_node_count == 1 || var.private_api_dns_name != null
      error_message = "More than one control_plane entry requires private_api_dns_name."
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
      condition     = local.bootstrap_public_dns_zone_id == null || try(length(local.stable_api_hostname) <= 253 && can(regex("^([[:alnum:]]([[:alnum:]-]{0,61}[[:alnum:]])?\\.){2,}[[:alpha:]]([[:alnum:]-]{0,61}[[:alnum:]])?$", local.stable_api_hostname)), false)
      error_message = "bootstrap_public.dns_zone_id requires a private_api_dns_name with at least three DNS labels."
    }
    precondition {
      condition     = var.talos_access_transport != "vpn" || var.talos_api_endpoint != "" || local.stable_api_hostname != null || local.control_plane_ip_set
      error_message = "VPN access requires a control_plane private_ip, bootstrap_public.dns_zone_id, or an explicit talos_api_endpoint."
    }
    precondition {
      condition     = var.control_plane_public_ip_enabled || (var.talos_api_endpoint != null && var.api_dns == null && (var.private_api_dns_name != null || local.control_plane_ip_set))
      error_message = "control_plane_public_ip_enabled = false requires talos_api_endpoint, private_api_dns_name or a control_plane private_ip, and no api_dns."
    }
  }
}

###########################################################################
## Bootstrap
###########################################################################

# NOTE: OpenTofu 1.8 forgets these legacy entries without destroying them.
removed {
  from = talos_machine_configuration_apply.control_plane
}

removed {
  from = talos_machine_bootstrap.this
}

removed {
  from = terraform_data.kube_upgrade
}

resource "talos_machine" "control_plane" {
  count                           = local.control_plane_node_count
  client_configuration            = sensitive(local.client_configuration)
  machine_configuration           = data.talos_machine_configuration.control_plane_runtime.machine_configuration
  endpoint                        = local.talos_api_endpoint
  node                            = aws_instance.control_plane[count.index].private_ip
  image                           = local.upgrade_installer_image
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  # DNS and Talos ingress must exist before the first API call.
  depends_on = [
    aws_route53_record.api,
    aws_route53_record.private_api,
    aws_route53_record.bootstrap_public,
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
    aws_lb_listener.private_talos,
    aws_lb_target_group_attachment.private_talos,
    aws_vpc_security_group_ingress_rule.private_talos_source,
    aws_vpc_security_group_ingress_rule.private_talos_cidr,
    aws_vpc_security_group_ingress_rule.private_talos_nodes,
    aws_vpc_security_group_egress_rule.private_talos_nodes,
    # NOTE: The OS wrapper sequences controller upgrades before the provider reconciles the installer.
    terraform_data.talos_upgrade,
  ]

  # A replacement reuses the fixed IP, so node never changes; without this the new instance keeps
  # user data only and its API server rejects tokens from the shared OIDC issuer.
  lifecycle {
    # NOTE: Run OS changes through the serial controller upgrade instead of per-machine updates.
    ignore_changes       = [image]
    replace_triggered_by = [aws_instance.control_plane[count.index].id]

    precondition {
      condition     = local.installer_image_matches_version
      error_message = "installer_image must be tagged with talos_version, so upgraded and newly launched nodes run the same release."
    }
  }
}

locals {
  bootstrap_node = aws_instance.control_plane[0].private_ip
}

resource "talos_cluster" "this" {
  depends_on           = [talos_machine.control_plane]
  client_configuration = sensitive(local.client_configuration)
  endpoint             = local.talos_api_endpoint
  node                 = local.bootstrap_node
  control_plane_nodes  = aws_instance.control_plane[*].private_ip
  kubernetes_version   = var.kube_version

  lifecycle {
    # NOTE: The bootstrap controller address can change when its instance is replaced.
    ignore_changes = [node]
  }
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_cluster.this]
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

###########################################################################
## Version upgrades
###########################################################################

locals {
  # Gated like pre_membership_snapshot: a new cluster has no running controllers to upgrade.
  version_upgrades_needed    = var.version_upgrades_enabled && length(data.aws_instances.existing_control_plane.ids) > 0
  configured_installer_image = var.image_factory_schematic_id == null ? var.installer_image : "factory.talos.dev/aws-installer/${var.image_factory_schematic_id}:${var.talos_version}"
  # NOTE: Official AMIs ship the vanilla Image Factory schematic.
  upgrade_installer_image         = coalesce(local.configured_installer_image, "factory.talos.dev/aws-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:${var.talos_version}")
  installer_image_matches_version = endswith(local.upgrade_installer_image, ":${var.talos_version}")
  upgrade_args                    = "--endpoint '${local.talos_api_endpoint}' --nodes '${join(",", sort(data.aws_instances.existing_control_plane.private_ips))}'"
  upgrade_environment = {
    TALOS_CA  = local.client_configuration.ca_certificate
    TALOS_CRT = local.client_configuration.client_certificate
    TALOS_KEY = local.client_configuration.client_key
  }
}

# NOTE: Legacy callers keep the version trigger. A schematic can change without a version change.
resource "terraform_data" "talos_upgrade" {
  count            = local.version_upgrades_needed ? 1 : 0
  triggers_replace = [var.image_factory_schematic_id == null ? var.talos_version : local.upgrade_installer_image]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = local.upgrade_environment
    command     = "python3 '${path.module}/scripts/version_upgrade.py' talos ${local.upgrade_args} --target '${var.talos_version}' --image '${local.upgrade_installer_image}'${var.image_factory_schematic_id == null ? "" : " --schematic-id '${var.image_factory_schematic_id}'"}"
  }

  lifecycle {
    precondition {
      condition     = local.installer_image_matches_version
      error_message = "installer_image must be tagged with talos_version, so upgraded and newly launched nodes run the same release."
    }
  }
}
