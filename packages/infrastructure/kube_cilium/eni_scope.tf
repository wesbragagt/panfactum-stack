data "aws_partition" "eni" {
  count = local.scoped_eni ? 1 : 0
}

data "aws_caller_identity" "eni" {
  count = local.scoped_eni ? 1 : 0
}

data "aws_s3_bucket" "oidc" {
  count  = local.scoped_eni && var.oidc_issuer_url == null ? 1 : 0
  bucket = "${local.cluster_name}-oidc-${data.aws_caller_identity.eni[0].account_id}"
}

data "aws_iam_openid_connect_provider" "talos" {
  count = local.scoped_eni ? 1 : 0
  arn   = var.oidc_provider_arn
  url   = var.oidc_provider_arn == null ? local.oidc_issuer_url : null

  lifecycle {
    postcondition {
      condition = (
        split(":", self.arn)[4] == data.aws_caller_identity.eni[0].account_id &&
        trimprefix(trimsuffix(self.url, "/"), "https://") == trimprefix(trimsuffix(local.oidc_issuer_url, "/"), "https://") &&
        contains(self.client_id_list, "sts.amazonaws.com")
      )
      error_message = "The Talos OIDC provider must match the cluster issuer in the current account and support the sts.amazonaws.com audience."
    }
  }
}

data "aws_security_group" "talos_nodes" {
  count = local.scoped_eni ? 1 : 0

  filter {
    name   = "group-name"
    values = ["${local.cluster_name}-nodes"]
  }
}

data "aws_subnets" "talos_private" {
  count = local.scoped_eni ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_security_group.talos_nodes[0].vpc_id]
  }

  tags = {
    "panfactum.com/type" = "private"
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "No Panfactum private subnets were found in the Talos node security group's VPC."
    }
  }
}

data "aws_subnet" "talos_private" {
  for_each = local.scoped_eni ? toset(data.aws_subnets.talos_private[0].ids) : toset([])
  id       = each.key
}

locals {
  oidc_issuer_url = var.oidc_issuer_url != null ? var.oidc_issuer_url : (
    local.scoped_eni ? "https://${data.aws_s3_bucket.oidc[0].bucket_regional_domain_name}" : null
  )
  oidc_provider_arn = local.scoped_eni ? data.aws_iam_openid_connect_provider.talos[0].arn : var.oidc_provider_arn

  private_subnets_by_name = { for id, subnet in data.aws_subnet.talos_private : subnet.tags["Name"] => id }
  eni_arn_prefix          = local.scoped_eni ? "arn:${data.aws_partition.eni[0].partition}:ec2:${data.aws_region.region.region}:${data.aws_caller_identity.eni[0].account_id}" : null
  eni_owner_tag           = { "ec2:ResourceTag/homelab-cluster" = local.eni_cluster_tag }

  # NOTE: Preserve existing policy names and statement IDs when adopting an inline policy.
  eni_policy_prefix = local.scoped_eni ? trimprefix(local.cluster_name, "${data.pf_metadata.metadata.environment}-") : null
  eni_policy_sid    = local.scoped_eni ? replace(title(replace(local.eni_policy_prefix, "-", " ")), "/[^a-zA-Z0-9]/", "") : null
}

resource "aws_iam_role_policy" "eni_scope" {
  count = local.scoped_eni ? 1 : 0

  name = "${local.eni_policy_prefix}-eni-scope"
  role = module.aws_permissions[0].role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid         = "CreateOnlyIn${local.eni_policy_sid}SubnetsAndSG"
        Effect      = "Deny"
        Action      = ["ec2:CreateNetworkInterface"]
        NotResource = concat([for id in local.eni_subnet_ids : "${local.eni_arn_prefix}:subnet/${id}"], ["${local.eni_arn_prefix}:security-group/${data.aws_security_group.talos_nodes[0].id}", "${local.eni_arn_prefix}:network-interface/*"])
      },
      {
        Sid       = "CreateOnlyTaggedENIs"
        Effect    = "Deny"
        Action    = ["ec2:CreateNetworkInterface"]
        Resource  = "${local.eni_arn_prefix}:network-interface/*"
        Condition = { StringNotEquals = { "aws:RequestTag/homelab-cluster" = local.eni_cluster_tag } }
      },
      {
        Sid       = "MutateOnly${local.eni_policy_sid}ENIs"
        Effect    = "Deny"
        Action    = ["ec2:DeleteNetworkInterface", "ec2:ModifyNetworkInterfaceAttribute", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses", "ec2:AttachNetworkInterface", "ec2:DetachNetworkInterface"]
        Resource  = "${local.eni_arn_prefix}:network-interface/*"
        Condition = { StringNotEquals = local.eni_owner_tag }
      },
      {
        Sid       = "AttachOnlyTo${local.eni_policy_sid}Instances"
        Effect    = "Deny"
        Action    = ["ec2:AttachNetworkInterface"]
        Resource  = "${local.eni_arn_prefix}:instance/*"
        Condition = { StringNotEquals = { "ec2:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned" } }
      },
      {
        Sid       = "TagOnly${local.eni_policy_sid}ENIs"
        Effect    = "Deny"
        Action    = ["ec2:CreateTags"]
        Resource  = "${local.eni_arn_prefix}:network-interface/*"
        Condition = { StringNotEquals = merge(local.eni_owner_tag, { "ec2:CreateAction" = "CreateNetworkInterface" }) }
      },
      {
        Sid         = "TagNothingElse"
        Effect      = "Deny"
        Action      = ["ec2:CreateTags"]
        NotResource = "${local.eni_arn_prefix}:network-interface/*"
      },
    ]
  })

  lifecycle {
    precondition {
      condition     = length(setsubtract(local.eni_subnet_ids, values(local.private_subnets_by_name))) == 0
      error_message = "All Cilium ENI subnets must be Panfactum private subnets in the Talos node security group's VPC."
    }
  }
}
