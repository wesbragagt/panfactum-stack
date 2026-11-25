locals {
  managed_enrollment_name = "/${var.name}/headscale-router-enrollment"
  managed_enrollment_arn  = var.headscale == null ? null : "arn:${data.aws_partition.headscale[0].partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.headscale[0].account_id}:parameter${local.managed_enrollment_name}"
}

data "aws_partition" "headscale" {
  count = var.headscale == null ? 0 : 1
}

data "aws_caller_identity" "headscale" {
  count = var.headscale == null ? 0 : 1
}

data "aws_route53_zone" "managed_headscale" {
  count        = var.headscale == null ? 0 : 1
  zone_id      = var.headscale.zone_id
  private_zone = false
}

resource "aws_eip" "headscale" {
  count  = var.headscale == null ? 0 : 1
  domain = "vpc"
  tags   = data.pf_aws_tags.tags.tags
}

resource "aws_route53_record" "managed_headscale" {
  count           = var.headscale == null ? 0 : 1
  zone_id         = var.headscale.zone_id
  name            = var.headscale.hostname
  type            = "A"
  ttl             = 60
  records         = [aws_eip.headscale[0].public_ip]
  allow_overwrite = false

  lifecycle {
    precondition {
      condition = !data.aws_route53_zone.managed_headscale[0].private_zone && (
        var.headscale.hostname == lower(trimsuffix(data.aws_route53_zone.managed_headscale[0].name, ".")) ||
        endswith(var.headscale.hostname, ".${lower(trimsuffix(data.aws_route53_zone.managed_headscale[0].name, "."))}")
      )
      error_message = "Managed Headscale requires a hostname in the supplied public Route 53 zone."
    }
  }
}

resource "aws_security_group" "headscale" {
  count       = var.headscale == null ? 0 : 1
  name_prefix = "${var.name}-headscale-"
  description = "Headscale HTTPS and certificate validation"
  vpc_id      = var.vpc_id
  tags        = data.pf_aws_tags.tags.tags
}

resource "aws_vpc_security_group_ingress_rule" "headscale" {
  count             = var.headscale == null ? 0 : 1
  security_group_id = aws_security_group.headscale[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "headscale" {
  count             = var.headscale == null ? 0 : 1
  security_group_id = aws_security_group.headscale[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "headscale" {
  count              = var.headscale == null ? 0 : 1
  name_prefix        = "${var.name}-headscale-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = data.pf_aws_tags.tags.tags
}

resource "aws_iam_role_policy_attachment" "headscale_ssm" {
  count      = var.headscale == null ? 0 : 1
  role       = aws_iam_role.headscale[0].name
  policy_arn = "arn:${data.aws_partition.headscale[0].partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "headscale_enrollment" {
  count = var.headscale == null ? 0 : 1
  role  = aws_iam_role.headscale[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = local.managed_enrollment_arn
      },
      {
        Effect      = "Deny"
        Action      = ["ssm:GetParameter", "ssm:GetParameters"]
        NotResource = local.managed_enrollment_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "headscale" {
  count       = var.headscale == null ? 0 : 1
  name_prefix = "${var.name}-headscale-"
  role        = aws_iam_role.headscale[0].name
  tags        = data.pf_aws_tags.tags.tags
}

resource "aws_ebs_volume" "headscale" {
  count             = var.headscale == null ? 0 : 1
  availability_zone = data.aws_subnet.router[var.subnets[0]].availability_zone
  encrypted         = true
  size              = 8
  type              = "gp3"
  tags              = merge(data.pf_aws_tags.tags.tags, { Name = "${var.name}-headscale-data" })
}

resource "aws_instance" "headscale" {
  count                       = var.headscale == null ? 0 : 1
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = "t4g.micro"
  subnet_id                   = data.aws_subnet.router[var.subnets[0]].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.headscale[0].id]
  iam_instance_profile        = aws_iam_instance_profile.headscale[0].name
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted = true
  }

  user_data = templatefile("${path.module}/headscale.sh.tftpl", {
    region    = data.aws_region.current.region
    volume_id = replace(aws_ebs_volume.headscale[0].id, "-", "")
    parameter = local.managed_enrollment_name
    config = jsonencode({
      server_url                        = local.headscale_url
      listen_addr                       = "0.0.0.0:443"
      metrics_listen_addr               = "127.0.0.1:9090"
      grpc_listen_addr                  = "127.0.0.1:50443"
      noise                             = { private_key_path = "/var/lib/headscale/noise_private.key" }
      prefixes                          = { v4 = "100.64.0.0/10", v6 = "fd7a:115c:a1e0::/48" }
      derp                              = { urls = ["https://controlplane.tailscale.com/derpmap/default"], auto_update_enabled = true, update_frequency = "3h" }
      disable_check_updates             = true
      ephemeral_node_inactivity_timeout = "30m"
      database = {
        type   = "sqlite"
        sqlite = { path = "/var/lib/headscale/db.sqlite", write_ahead_log = true }
      }
      acme_url                       = "https://acme-v02.api.letsencrypt.org/directory"
      tls_letsencrypt_hostname       = var.headscale.hostname
      tls_letsencrypt_cache_dir      = "/var/lib/headscale/acme"
      tls_letsencrypt_challenge_type = "TLS-ALPN-01"
      policy                         = { mode = "file", path = "/etc/headscale/policy.json" }
      dns = {
        magic_dns          = false
        override_local_dns = false
        nameservers        = { split = { for domain in var.split_dns_domains : domain => [local.resolver] } }
      }
      unix_socket            = "/run/headscale/headscale.sock"
      unix_socket_permission = "0770"
    })
    policy = jsonencode({
      tagOwners     = { "tag:subnet-router" = [] }
      autoApprovers = { routes = { for cidr in local.routes : cidr => ["tag:subnet-router"] } }
      acls          = [{ action = "accept", src = ["autogroup:member"], dst = [for cidr in local.routes : "${cidr}:*"] }]
    })

  })

  lifecycle {
    ignore_changes = [ami]

  }

  tags = merge(data.pf_aws_tags.tags.tags, { Name = "${var.name}-headscale" })
  depends_on = [
    aws_iam_role_policy_attachment.headscale_ssm,
    aws_iam_role_policy.headscale_enrollment,
    aws_route53_record.managed_headscale
  ]
}

resource "aws_eip_association" "headscale" {
  count         = var.headscale == null ? 0 : 1
  allocation_id = aws_eip.headscale[0].id
  instance_id   = aws_instance.headscale[0].id
}

resource "aws_volume_attachment" "headscale" {
  count                          = var.headscale == null ? 0 : 1
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.headscale[0].id
  instance_id                    = aws_instance.headscale[0].id
  stop_instance_before_detaching = true
}
