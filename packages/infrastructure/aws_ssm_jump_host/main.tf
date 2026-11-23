terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

locals {
  name = "${var.cluster_name}-ssm-tunnel"
  tags = {
    Name                    = local.name
    "panfactum.com/module"  = "aws_ssm_jump_host"
    "panfactum.com/cluster" = var.cluster_name
  }
}

data "aws_partition" "current" {}

data "aws_subnet" "selected" {
  id = var.subnet_id

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id
      error_message = "The SSM jump host subnet must belong to the supplied VPC."
    }
  }
}

data "aws_ec2_instance_type" "host" {
  instance_type = var.instance_type

  lifecycle {
    postcondition {
      condition     = contains(self.supported_architectures, "arm64")
      error_message = "The SSM jump host instance type must support arm64."
    }
  }
}

# AL2023 ships the SSM Agent.
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_iam_role" "host" {
  name = local.name
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.${data.aws_partition.current.dns_suffix}" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = local.name
  role = aws_iam_role.host.name
  tags = local.tags
}

resource "aws_security_group" "host" {
  name        = local.name
  description = "SSM jump host for ${var.cluster_name}"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

# The SSM agent reaches AWS over the subnet's outbound route.
resource "aws_vpc_security_group_egress_rule" "host" {
  security_group_id = aws_security_group.host.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = data.aws_ec2_instance_type.host.instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = false
  tags                        = local.tags

  # Give the agent a route and credentials when it starts.
  depends_on = [aws_iam_role_policy_attachment.ssm, aws_vpc_security_group_egress_rule.host]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  lifecycle {
    # Replacing the instance would interrupt operator sessions.
    ignore_changes = [ami]
  }
}
