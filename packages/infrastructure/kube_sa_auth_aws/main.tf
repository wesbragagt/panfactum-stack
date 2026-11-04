terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.35.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.1.6"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  custom_oidc_requested = var.oidc_provider_arn != null || var.oidc_issuer_url != null
  kube_oidc_provider = trimprefix(trimsuffix(
    var.oidc_issuer_url != null ? var.oidc_issuer_url : try(data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer, ""), "/"
  ), "https://")
  oidc_principal = var.oidc_provider_arn != null ? var.oidc_provider_arn : "arn:aws:iam::${data.aws_caller_identity.main.account_id}:oidc-provider/${local.kube_oidc_provider}"
  ip_allow_list_with_defaults = concat(
    var.ip_allow_list,
    [for subnet in data.aws_subnet.cluster_subnet_info : subnet.tags["panfactum.com/public-ip"] if contains(keys(subnet.tags), "panfactum.com/public-ip")],
    [for subnet in data.aws_subnet.cluster_subnet_info : subnet.cidr_block]
  )
  cluster_name = data.pf_metadata.metadata.kube_cluster_name
}

data "aws_caller_identity" "main" {}
data "aws_region" "main" {}

data "pf_aws_tags" "tags" {
  module = "kube_sa_auth_aws"
}
data "pf_metadata" "metadata" {}

# ################################################################################
# IP Auto Discovery
# ################################################################################

data "aws_subnets" "cluster_subnets" {
  count = var.ip_restrictions_enabled && var.cluster_subnet_ids == null ? 1 : 0
  filter {
    name   = "tag-key"
    values = ["kubernetes.io/cluster/${local.cluster_name}"]
  }
}

data "aws_subnet" "cluster_subnet_info" {
  for_each = var.ip_restrictions_enabled ? (var.cluster_subnet_ids != null ? var.cluster_subnet_ids : toset(data.aws_subnets.cluster_subnets[0].ids)) : toset([])
  id       = each.key
}

# ################################################################################
# IAM Permissions
# ################################################################################

resource "aws_iam_policy" "service_account" {
  name_prefix = "${substr(var.service_account, 0, 37)}-"
  description = "Provides IAM permissions for ${var.service_account_namespace}/${var.service_account} in ${local.cluster_name}."
  policy      = var.iam_policy_json
  tags = merge(data.pf_aws_tags.tags.tags, {
    description = "Provides IAM permissions for ${var.service_account_namespace}/${var.service_account} in ${local.cluster_name}."
  })
}

data "aws_eks_cluster" "cluster" {
  count = local.custom_oidc_requested ? 0 : 1
  name  = local.cluster_name
}

data "aws_iam_policy_document" "service_account_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      identifiers = [local.oidc_principal]
      type        = "Federated"
    }
    condition {
      test     = "StringEquals"
      values   = ["system:serviceaccount:${var.service_account_namespace}:${var.service_account}"]
      variable = "${local.kube_oidc_provider}:sub"
    }
    dynamic "condition" {
      for_each = local.custom_oidc_requested ? [true] : []
      content {
        test     = "StringEquals"
        values   = ["sts.amazonaws.com"]
        variable = "${local.kube_oidc_provider}:aud"
      }
    }
  }
}

resource "aws_iam_role" "service_account" {
  name_prefix        = "${substr(var.service_account, 0, 37)}-"
  description        = "IAM role for ${var.service_account_namespace}/${var.service_account} in ${local.cluster_name}."
  assume_role_policy = data.aws_iam_policy_document.service_account_assume.json
  tags = merge(data.pf_aws_tags.tags.tags, {
    description = "IAM role for ${var.service_account_namespace}/${var.service_account} in ${local.cluster_name}."
  })
  max_session_duration = 43200
  lifecycle {
    precondition {
      condition     = (var.oidc_provider_arn == null) == (var.oidc_issuer_url == null)
      error_message = "Provide oidc_provider_arn and oidc_issuer_url together, or leave both null for EKS discovery."
    }
    precondition {
      condition     = local.custom_oidc_requested && var.oidc_provider_arn != null ? endswith(var.oidc_provider_arn, ":oidc-provider/${local.kube_oidc_provider}") && split(":", var.oidc_provider_arn)[4] == data.aws_caller_identity.main.account_id : true
      error_message = "The explicit OIDC provider ARN must match the issuer URL and the role's AWS account."
    }
  }
}

resource "aws_iam_policy_attachment" "service_account" {
  name       = aws_iam_policy.service_account.name
  policy_arn = aws_iam_policy.service_account.arn
  roles      = [aws_iam_role.service_account.name]
}

data "aws_iam_policy_document" "ip_blocks" {
  count = var.ip_restrictions_enabled ? 1 : 0
  statement {
    effect    = "Deny"
    resources = ["*"]
    // Since we use vpc endpoints for S3
    // we need to ignore them for this global deny
    not_actions = ["s3:*"]

    // Only allow access from inside our cluster
    condition {
      test     = "NotIpAddress"
      values   = local.ip_allow_list_with_defaults
      variable = "aws:SourceIp"
    }

    // Do not block requests made by AWS services on behalf of the role
    condition {
      test     = "BoolIfExists"
      values   = ["false"]
      variable = "aws:ViaAWSService"
    }
  }

  statement {
    effect = "Deny"
    actions = concat(
      [
        "s3:AbortMultipartUpload",
        "s3:AssociateAccessGrantsIdentityCenter",
        "s3:BypassGovernanceRetention",
        "s3:Create*",
        "s3:Delete*",
        "s3:Describe*",
        "s3:DissociateAccessGrantsIdentityCenter",
        "s3:GetAccess*",
        "s3:GetAccountPublicAccessBlock",
        "s3:GetAnalyticsConfiguration",
        "s3:GetBucket*",
        "s3:GetData*",
        "s3:GetEncryptionConfiguration",
        "s3:GetIntelligentTieringConfiguration",
        "s3:GetInventoryConfiguration",
        "s3:GetInventoryReport",
        "s3:GetJob*",
        "s3:GetLifecycleConfiguration",
        "s3:GetMetricsConfiguration",
        "s3:GetMulti*",
        "s3:GetReplicationConfiguration",
        "s3:GetStorage*",
        "s3:Initiate*",
        "s3:List*",
        "s3:ObjectOwnerOverrideToBucketOwner",
        "s3:Pause*",
        "s3:PutAccelerateConfiguration",
        "s3:PutAccess*",
        "s3:PutAccountPublicAccessBlock",
        "s3:PutAnalyticsConfiguration",
        "s3:PutBucket*",
        "s3:PutData*",
        "s3:PutEncryptionConfiguration",
        "s3:PutIntelligentTieringConfiguration",
        "s3:PutInventoryConfiguration",
        "s3:PutJob*",
        "s3:PutLifecycleConfiguration",
        "s3:PutMetricsConfiguration",
        "s3:PutMulti*",
        "s3:PutReplicationConfiguration",
        "s3:PutStorage*",
        "s3:PutTagging",
        "s3:PutVersioning",
        "s3:Replicat*",
        "s3:Restore*",
        "s3:Submit*",
        "s3:TagResource",
        "s3:UntagResource",
        "s3:Update*"
      ],
      var.allow_public_s3_presigned_urls ? [] : ["s3:GetObject*", "s3:PutObject*"]
    )
    resources = ["*"]

    // Only allow access from inside our cluster
    condition {
      test     = "NotIpAddress"
      values   = local.ip_allow_list_with_defaults
      variable = "aws:VpcSourceIp"
    }

    // Do not block requests made by AWS services on behalf of the role
    condition {
      test     = "BoolIfExists"
      values   = ["false"]
      variable = "aws:ViaAWSService"
    }
  }
}

resource "aws_iam_policy" "ip_blocks" {
  count       = var.ip_restrictions_enabled ? 1 : 0
  name_prefix = "${substr(var.service_account, 0, 26)}-ip-blocks-"
  description = "Restricts ${var.service_account_namespace}/${var.service_account} in ${local.cluster_name} to cluster IPs."
  policy      = data.aws_iam_policy_document.ip_blocks[0].json
  tags = merge(data.pf_aws_tags.tags.tags, {
    description = "Restricts ${var.service_account_namespace}/${var.service_account} in ${local.cluster_name} to cluster IPs."
  })
}

resource "aws_iam_policy_attachment" "ip_blocks" {
  count      = var.ip_restrictions_enabled ? 1 : 0
  name       = "${aws_iam_policy.service_account.name}-ip-blocks"
  policy_arn = aws_iam_policy.ip_blocks[0].arn
  roles      = [aws_iam_role.service_account.name]
}

# ################################################################################
# Provide the annotation required by IRSA
# ################################################################################

resource "kubernetes_annotations" "service_account" {
  count       = var.annotate_service_account ? 1 : 0
  api_version = "v1"
  kind        = "ServiceAccount"
  metadata {
    name      = var.service_account
    namespace = var.service_account_namespace
  }
  field_manager = "terraform-aws"
  force         = true
  annotations = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.service_account.arn
  }
}

# Preserve existing EKS state addresses with the default IP restriction setting.
moved {
  from = aws_iam_policy.ip_blocks
  to   = aws_iam_policy.ip_blocks[0]
}
moved {
  from = aws_iam_policy_attachment.ip_blocks
  to   = aws_iam_policy_attachment.ip_blocks[0]
}
