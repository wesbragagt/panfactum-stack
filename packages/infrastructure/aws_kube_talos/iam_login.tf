locals {
  iam_login_roles = {
    Superuser        = { group = "pf:superusers", arns = data.aws_iam_roles.iam_login_superuser.arns }
    Admin            = { group = "pf:admins", arns = data.aws_iam_roles.iam_login_admin.arns }
    Reader           = { group = "pf:readers", arns = data.aws_iam_roles.iam_login_reader.arns }
    RestrictedReader = { group = "pf:restricted-readers", arns = data.aws_iam_roles.iam_login_restricted_reader.arns }
  }
  # NOTE: A role ARN found in two sets fails with a duplicate key, as aws_eks fails on a duplicate access entry, instead of silently picking a group.
  iam_login_role_groups = merge(
    {
      for pair in flatten([for role in local.iam_login_roles : [for arn in role.arns : { arn = arn, group = role.group }]]) : pair.arn => pair.group
    },
    # NOTE: The root ARN is outside iam_login_roles because the iam_login output reads that local and must list only Identity Center roles.
    { "arn:${data.aws_partition.backup.partition}:iam::${data.aws_caller_identity.oidc.account_id}:root" = "pf:superusers" }
  )
}

# NOTE: These regexes and the path match aws_eks, so the same Identity Center roles get the same groups on EKS and Talos.
data "aws_iam_roles" "iam_login_superuser" {
  name_regex  = "AWSReservedSSO_Superuser.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_roles" "iam_login_admin" {
  name_regex  = "AWSReservedSSO_Admin.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_roles" "iam_login_reader" {
  name_regex  = "AWSReservedSSO_Reader.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_roles" "iam_login_restricted_reader" {
  name_regex  = "AWSReservedSSO_RestrictedReader.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

# NOTE: The account must have outbound identity federation enabled. It is the source of both the issuer and the STS tokens operators present.
data "aws_iam_outbound_web_identity_federation" "iam_login" {}
