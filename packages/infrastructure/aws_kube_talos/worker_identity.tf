locals {
  worker_identity_name_prefix = coalesce(var.worker_identity.name_prefix, substr(var.cluster_name, 0, 24))
  worker_identity_tags = {
    "Name"                  = "${local.worker_identity_name_prefix}-talos-worker"
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
      identifiers = ["ec2.${data.aws_partition.backup.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "worker" {
  name_prefix        = "${local.worker_identity_name_prefix}-worker-"
  description        = "EC2 identity for Talos workers in ${var.cluster_name}; private ECR image reads only"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.worker_identity_tags
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
    resources = ["arn:${data.aws_partition.backup.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.backup.account_id}:repository/*"]
  }
}

resource "aws_iam_role_policy" "ecr_read" {
  name_prefix = "ecr-read-"
  role        = aws_iam_role.worker.id
  policy      = data.aws_iam_policy_document.ecr_read.json
}

resource "aws_iam_instance_profile" "worker" {
  name_prefix = "${local.worker_identity_name_prefix}-worker-"
  role        = aws_iam_role.worker.name
  tags        = local.worker_identity_tags
}

data "aws_iam_policy_document" "cache_import" {
  count = length(var.worker_identity.ecr_cache_prefixes) == 0 ? 0 : 1
  statement {
    sid       = "ScopedCacheFirstImport"
    actions   = ["ecr:CreateRepository", "ecr:BatchImportUpstreamImage"]
    resources = [for prefix in sort(tolist(var.worker_identity.ecr_cache_prefixes)) : "arn:${data.aws_partition.backup.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.backup.account_id}:repository/${prefix}/*"]
  }
}

resource "aws_iam_role_policy" "cache_import" {
  count       = length(var.worker_identity.ecr_cache_prefixes) == 0 ? 0 : 1
  name_prefix = "ecr-cache-import-"
  role        = aws_iam_role.worker.id
  policy      = data.aws_iam_policy_document.cache_import[0].json
}

resource "aws_iam_role" "controller" {
  count              = var.worker_identity.controller_instance_profile_enabled ? 1 : 0
  name_prefix        = "${local.worker_identity_name_prefix}-ctrl-"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.worker_identity_tags
}

data "aws_iam_policy_document" "controller_read" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  dynamic "statement" {
    for_each = length(var.worker_identity.ecr_cache_prefixes) == 0 ? [] : [1]
    content {
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      resources = [for prefix in sort(tolist(var.worker_identity.ecr_cache_prefixes)) : "arn:${data.aws_partition.backup.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.backup.account_id}:repository/${prefix}/*"]
    }
  }
  dynamic "statement" {
    for_each = length(var.worker_identity.controller_additional_ecr_repositories) == 0 ? [] : [1]
    content {
      sid       = "AdditionalExactRepositoryReads"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      resources = [for name in sort(tolist(var.worker_identity.controller_additional_ecr_repositories)) : "arn:${data.aws_partition.backup.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.backup.account_id}:repository/${name}"]
    }
  }
}

resource "aws_iam_role_policy" "controller_read" {
  count       = var.worker_identity.controller_instance_profile_enabled ? 1 : 0
  name_prefix = "ecr-read-"
  role        = aws_iam_role.controller[0].id
  policy      = data.aws_iam_policy_document.controller_read.json
}

resource "aws_iam_role_policy" "controller_import" {
  count       = var.worker_identity.controller_instance_profile_enabled && length(var.worker_identity.ecr_cache_prefixes) > 0 ? 1 : 0
  name_prefix = "ecr-cache-import-"
  role        = aws_iam_role.controller[0].id
  policy      = data.aws_iam_policy_document.cache_import[0].json
}

resource "aws_iam_instance_profile" "controller" {
  count       = var.worker_identity.controller_instance_profile_enabled ? 1 : 0
  name_prefix = "${local.worker_identity_name_prefix}-ctrl-"
  role        = aws_iam_role.controller[0].name
  tags        = local.worker_identity_tags
}
