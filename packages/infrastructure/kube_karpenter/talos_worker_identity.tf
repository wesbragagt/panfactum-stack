locals {
  talos_worker_identity_enabled    = var.cluster != null || var.talos_worker_identity != null
  manage_instance_profiles_enabled = !local.talos_worker_identity_enabled && var.manage_instance_profiles_enabled
  talos_worker_name_prefix         = coalesce(try(var.talos_worker_identity.name_prefix, null), substr(local.cluster_name, 0, 24))
  talos_worker_cache_prefixes      = var.talos_worker_identity == null ? toset([]) : var.talos_worker_identity.ecr_cache_prefixes
  talos_worker_tags = {
    "Name"                  = "${local.talos_worker_name_prefix}-talos-worker"
    "panfactum.com/module"  = "aws_talos_worker_identity"
    "panfactum.com/cluster" = local.cluster_name
  }
  talos_worker_ecr_repository_arn = local.talos_worker_identity_enabled ? "arn:${data.aws_partition.talos_worker[0].partition}:ecr:${data.aws_region.main.region}:${data.aws_caller_identity.main.account_id}:repository" : null
  worker_instance_profile_arn     = local.talos_worker_identity_enabled ? aws_iam_instance_profile.talos_worker[0].arn : var.existing_instance_profile_arn
}

data "aws_partition" "talos_worker" {
  count = local.talos_worker_identity_enabled ? 1 : 0
}

data "aws_iam_policy_document" "talos_worker_ec2_trust" {
  count = local.talos_worker_identity_enabled ? 1 : 0
  statement {
    sid     = "EC2AssumeRole"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.${data.aws_partition.talos_worker[0].dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "talos_worker" {
  count              = local.talos_worker_identity_enabled ? 1 : 0
  name_prefix        = "${local.talos_worker_name_prefix}-worker-"
  description        = "EC2 identity for Talos workers in ${local.cluster_name}; private ECR image reads only"
  assume_role_policy = data.aws_iam_policy_document.talos_worker_ec2_trust[0].json
  tags               = local.talos_worker_tags
}

data "aws_iam_policy_document" "talos_worker_ecr_read" {
  count = local.talos_worker_identity_enabled ? 1 : 0
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
    resources = ["${local.talos_worker_ecr_repository_arn}/*"]
  }
}

resource "aws_iam_role_policy" "talos_worker_ecr_read" {
  count       = local.talos_worker_identity_enabled ? 1 : 0
  name_prefix = "ecr-read-"
  role        = aws_iam_role.talos_worker[0].id
  policy      = data.aws_iam_policy_document.talos_worker_ecr_read[0].json
}

resource "aws_iam_instance_profile" "talos_worker" {
  count       = local.talos_worker_identity_enabled ? 1 : 0
  name_prefix = "${local.talos_worker_name_prefix}-worker-"
  role        = aws_iam_role.talos_worker[0].name
  tags        = local.talos_worker_tags
}

data "aws_iam_policy_document" "talos_worker_cache_import" {
  count = length(local.talos_worker_cache_prefixes) == 0 ? 0 : 1
  statement {
    sid       = "ScopedCacheFirstImport"
    actions   = ["ecr:CreateRepository", "ecr:BatchImportUpstreamImage"]
    resources = [for prefix in sort(tolist(local.talos_worker_cache_prefixes)) : "${local.talos_worker_ecr_repository_arn}/${prefix}/*"]
  }
}

resource "aws_iam_role_policy" "talos_worker_cache_import" {
  count       = length(local.talos_worker_cache_prefixes) == 0 ? 0 : 1
  name_prefix = "ecr-cache-import-"
  role        = aws_iam_role.talos_worker[0].id
  policy      = data.aws_iam_policy_document.talos_worker_cache_import[0].json
}

output "node_instance_profile" {
  description = "Name of the managed Talos worker instance profile for EC2NodeClass, or null for an external identity."
  value       = one(aws_iam_instance_profile.talos_worker[*].name)
  depends_on  = [aws_iam_role_policy.talos_worker_ecr_read, aws_iam_role_policy.talos_worker_cache_import]
}
