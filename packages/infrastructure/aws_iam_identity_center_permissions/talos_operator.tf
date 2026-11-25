module "talos_operator_policy" {
  count  = var.talos_operator_access == null ? 0 : 1
  source = "../aws_talos_operator_policy"

  access = var.talos_operator_access
}

locals {
  base_operator_policies = {
    admin             = module.aws_core_permissions.admin_policy_json
    reader            = module.aws_core_permissions.reader_policy_json
    restricted_reader = module.aws_core_permissions.restricted_reader_policy_json
    billing           = module.aws_core_permissions.billing_admin_policy_json
  }
  operator_policies = {
    for role, base in local.base_operator_policies : role => var.talos_operator_access == null ? base : jsonencode({
      Version = "2012-10-17"
      Statement = concat(jsondecode(base).Statement, jsondecode(
        role == "billing" ? module.talos_operator_policy[0].billing_policy_json : module.talos_operator_policy[0].ordinary_policy_json
      ).Statement)
    })
  }
}
