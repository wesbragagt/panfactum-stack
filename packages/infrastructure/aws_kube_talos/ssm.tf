variable "operator_tunnel_security_group_ids" {
  description = "Security groups of SSM tunnel hosts (for example one NAT per AZ) allowed to reach the private Kubernetes and Talos APIs."
  type        = list(string)
  default     = []
}

resource "aws_vpc_security_group_ingress_rule" "operator_tunnel" {
  for_each = {
    for pair in setproduct(var.operator_tunnel_security_group_ids, ["kubernetes", "talos"]) :
    "${pair[0]}-${pair[1]}" => { security_group_id = pair[0], name = pair[1], port = pair[1] == "kubernetes" ? 6443 : 50000 }
  }

  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = each.value.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "${each.value.name} API from SSM tunnel hosts"
}

variable "ssm_jump_host_enabled" {
  description = "Create an SSM jump host in the VPC that operators tunnel through to the private Kubernetes and Talos APIs."
  type        = bool
  default     = false
}

variable "ssm_jump_host_instance_type" {
  description = "Instance type of the SSM jump host. Must support arm64."
  type        = string
  default     = "t4g.nano"
}

variable "ssm_jump_host_subnet" {
  description = "Name tag of the private subnet for the SSM jump host. Defaults to the first entry of control_plane_subnets."
  type        = string
  default     = null
}

locals {
  # Retain the existing certificates and state addresses during the rollout.
  legacy_ssm_sans     = var.ssm_jump_host_enabled || length(var.operator_tunnel_security_group_ids) > 0 ? ["127.0.0.1"] : []
  ssm_jump_host_count = var.ssm_jump_host_enabled ? 1 : 0
  ssm_jump_host_name  = "${var.cluster_name}-ssm-tunnel"
}

data "aws_subnet" "ssm_jump_host" {
  count  = local.ssm_jump_host_count
  vpc_id = var.vpc_id
  filter {
    name   = "tag:Name"
    values = [coalesce(var.ssm_jump_host_subnet, var.control_plane_subnets[0])]
  }
}

# AL2023 ships the SSM agent
data "aws_ssm_parameter" "ssm_jump_host_ami" {
  count = local.ssm_jump_host_count
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_iam_role" "ssm_jump_host" {
  count = local.ssm_jump_host_count
  name  = local.ssm_jump_host_name
  tags  = data.pf_aws_tags.tags.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_jump_host" {
  count      = local.ssm_jump_host_count
  role       = aws_iam_role.ssm_jump_host[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_jump_host" {
  count = local.ssm_jump_host_count
  name  = local.ssm_jump_host_name
  role  = aws_iam_role.ssm_jump_host[0].name
  tags  = data.pf_aws_tags.tags.tags
}

# No ingress: SSM sessions are outbound-only through the NAT route
resource "aws_security_group" "ssm_jump_host" {
  count       = local.ssm_jump_host_count
  name        = local.ssm_jump_host_name
  description = "SSM jump host for ${var.cluster_name}"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = local.ssm_jump_host_name
  })
}

resource "aws_instance" "ssm_jump_host" {
  count                       = local.ssm_jump_host_count
  ami                         = data.aws_ssm_parameter.ssm_jump_host_ami[0].insecure_value
  instance_type               = var.ssm_jump_host_instance_type
  subnet_id                   = data.aws_subnet.ssm_jump_host[0].id
  vpc_security_group_ids      = [aws_security_group.ssm_jump_host[0].id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_jump_host[0].name
  associate_public_ip_address = false

  # Attach the SSM policy before the agent starts on a new host.
  depends_on = [aws_iam_role_policy_attachment.ssm_jump_host]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(data.pf_aws_tags.tags.tags, {
    Name = local.ssm_jump_host_name
  })

  # A new AMI must not replace the host while an operator session is open
  lifecycle {
    ignore_changes = [ami]
  }
}

# count, not for_each: the security group id is unknown at plan time
resource "aws_vpc_security_group_ingress_rule" "ssm_jump_host_kubernetes" {
  count                        = local.ssm_jump_host_count
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.ssm_jump_host[0].id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "kubernetes API from the SSM jump host"
}

resource "aws_vpc_security_group_ingress_rule" "ssm_jump_host_talos" {
  count                        = local.ssm_jump_host_count
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.ssm_jump_host[0].id
  ip_protocol                  = "tcp"
  from_port                    = 50000
  to_port                      = 50000
  description                  = "talos API from the SSM jump host"
}
