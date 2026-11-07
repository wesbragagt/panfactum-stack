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

# Separate from the existing read policy, retaining its default behavior.
data "aws_iam_policy_document" "cache_import" {
  count = length(var.ecr_cache_prefixes) == 0 ? 0 : 1
  statement {
    sid       = "ScopedCacheFirstImport"
    actions   = ["ecr:CreateRepository", "ecr:BatchImportUpstreamImage"]
    resources = [for prefix in sort(tolist(var.ecr_cache_prefixes)) : "arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${prefix}/*"]
  }
}

resource "aws_iam_role_policy" "cache_import" {
  count       = length(var.ecr_cache_prefixes) == 0 ? 0 : 1
  name_prefix = "ecr-cache-import-"
  role        = aws_iam_role.worker.id
  policy      = data.aws_iam_policy_document.cache_import[0].json
}

resource "aws_iam_role" "controller" {
  count              = var.controller_instance_id == null ? 0 : 1
  name_prefix        = "${var.name_prefix}-ctrl-"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "controller_read" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  dynamic "statement" {
    for_each = length(var.ecr_cache_prefixes) == 0 ? [] : [1]
    content {
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      resources = [for prefix in sort(tolist(var.ecr_cache_prefixes)) : "arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "controller_read" {
  count       = var.controller_instance_id == null ? 0 : 1
  name_prefix = "ecr-read-"
  role        = aws_iam_role.controller[0].id
  policy      = data.aws_iam_policy_document.controller_read.json
}

resource "aws_iam_role_policy" "controller_import" {
  count       = var.controller_instance_id == null || length(var.ecr_cache_prefixes) == 0 ? 0 : 1
  name_prefix = "ecr-cache-import-"
  role        = aws_iam_role.controller[0].id
  policy      = data.aws_iam_policy_document.cache_import[0].json
}

resource "aws_iam_instance_profile" "controller" {
  count       = var.controller_instance_id == null ? 0 : 1
  name_prefix = "${var.name_prefix}-ctrl-"
  role        = aws_iam_role.controller[0].name
  tags        = local.tags
}


# AWS provider has no standalone association resource. This guarded adoption
# intentionally has no destroy provisioner: removing state must never detach IAM.
resource "terraform_data" "controller_association" {
  count = var.controller_instance_id == null ? 0 : 1
  input = {
    instance = var.controller_instance_id
    profile  = aws_iam_instance_profile.controller[0].arn
  }
  lifecycle { prevent_destroy = true }
  provisioner "local-exec" {
    command = "python3 ${path.module}/associate.py"
    environment = {
      ASSOCIATION_INSTANCE = self.input.instance
      ASSOCIATION_PROFILE  = self.input.profile
      ASSOCIATION_REGION   = data.aws_region.current.region
    }
  }
}
