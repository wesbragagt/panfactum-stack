terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = {
    "Name"                  = "${var.name_prefix}-talos-worker"
    "panfactum.com/module"  = "aws_talos_worker_identity"
    "panfactum.com/cluster" = var.cluster_name
  }
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "EC2AssumeRole"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "worker" {
  name_prefix        = "${var.name_prefix}-worker-"
  description        = "EC2 identity for Talos workers in ${var.cluster_name}; private ECR image reads only"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ecr_read" {
  statement {
    sid       = "ECRAuthentication"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "RegionalAccountRepositoryReads"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/*"]
  }
}

resource "aws_iam_role_policy" "ecr_read" {
  name_prefix = "ecr-read-"
  role        = aws_iam_role.worker.id
  policy      = data.aws_iam_policy_document.ecr_read.json
}

resource "aws_iam_instance_profile" "worker" {
  name_prefix = "${var.name_prefix}-worker-"
  role        = aws_iam_role.worker.name
  tags        = local.tags
}
