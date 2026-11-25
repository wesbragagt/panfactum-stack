variable "access" {
  description = "One cluster's approved Session Manager targets, fixed documents, account and state scope."
  type = object({
    partition                = optional(string, "aws")
    account_id               = string
    region                   = string
    cluster_name             = string
    jump_host_id             = string
    additional_jump_host_ids = optional(set(string), [])
    kube_document_name       = optional(string)
    recovery_document_names  = optional(set(string), [])
    nat_host_ids             = set(string)
    audience                 = string
    state_object_arn         = string
  })

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:s3:::[a-z0-9.-]+/[^*?]+/[*]$", var.access.state_object_arn))
    error_message = "The state ARN must name a specific S3 bucket and cluster prefix ending in /*."
  }

  validation {
    condition = (
      can(regex("^[a-z0-9-]+$", var.access.partition))
      && can(regex("^[0-9]{12}$", var.access.account_id))
      && can(regex("^[a-z0-9-]+$", var.access.region))
      && can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", var.access.cluster_name))
      && alltrue([for id in setunion([var.access.jump_host_id], var.access.additional_jump_host_ids, var.access.nat_host_ids) :
        can(regex("^i-([0-9a-f]{8}|[0-9a-f]{17})$", id))
      ])
    )
    error_message = "The partition, account, region, cluster and host IDs must be concrete IAM resource identifiers."
  }

  validation {
    condition     = length(setintersection(setunion([var.access.jump_host_id], var.access.additional_jump_host_ids), var.access.nat_host_ids)) == 0
    error_message = "An approved jump host must not also be a privileged NAT target."
  }

  validation {
    condition = (
      (var.access.kube_document_name == null || can(regex("^[A-Za-z0-9_.-]{3,128}$", var.access.kube_document_name)))
      && alltrue([
        for name in var.access.recovery_document_names :
        can(regex("^[A-Za-z0-9_.-]{3,128}$", name))
      ])
      && !contains(setunion(["${var.access.cluster_name}-talos-forward"], var.access.recovery_document_names), coalesce(var.access.kube_document_name, "${var.access.cluster_name}-kube-forward"))
    )
    error_message = "Document names must be valid concrete SSM names and the ordinary Kubernetes document must be distinct from recovery documents."
  }
}

locals {
  ssm_arn          = "arn:${var.access.partition}:ssm:${var.access.region}:${var.access.account_id}"
  instance_arn     = "arn:${var.access.partition}:ec2:${var.access.region}:${var.access.account_id}:instance"
  jump_hosts       = [for id in setunion([var.access.jump_host_id], var.access.additional_jump_host_ids) : "${local.instance_arn}/${id}"]
  protected_hosts  = concat(local.jump_hosts, [for id in var.access.nat_host_ids : "${local.instance_arn}/${id}"])
  kube_document    = "${local.ssm_arn}:document/${coalesce(var.access.kube_document_name, "${var.access.cluster_name}-kube-forward")}"
  account_scope    = { "aws:PrincipalAccount" = var.access.account_id }
  regional_scope   = merge(local.account_scope, { "aws:RequestedRegion" = var.access.region })
  session_owner    = "$${aws:userid}"
  controller_names = { "ec2:ResourceTag/Name" = "${var.access.cluster_name}-control-plane-*" }

  state_deny = {
    Sid       = "TalosDenyCanaryState"
    Effect    = "Deny"
    Action    = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject"]
    Resource  = var.access.state_object_arn
    Condition = { StringEquals = local.account_scope }
  }

  # Admin already has an account-wide Allow for these actions.
  ordinary_statements = [
    {
      Sid         = "TalosDenyAlternateSessions"
      Effect      = "Deny"
      Action      = "ssm:StartSession"
      NotResource = concat(local.jump_hosts, [local.kube_document])
      Condition   = { StringEquals = local.regional_scope }
    },
    # NOTE: AWS can omit this key for an explicit document. The exact ARN allowlist still applies.
    {
      Sid      = "TalosDenyFailedDocumentCheck"
      Effect   = "Deny"
      Action   = "ssm:StartSession"
      Resource = local.jump_hosts
      Condition = {
        StringEquals = local.regional_scope
        Bool         = { "ssm:SessionDocumentAccessCheck" = "false" }
      }
    },
    {
      Sid      = "TalosAllowKubernetesTarget"
      Effect   = "Allow"
      Action   = "ssm:StartSession"
      Resource = local.jump_hosts
      Condition = {
        StringEquals = local.regional_scope
        BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" }
      }
    },
    {
      Sid       = "TalosAllowKubernetesDocument"
      Effect    = "Allow"
      Action    = "ssm:StartSession"
      Resource  = local.kube_document
      Condition = { StringEquals = local.regional_scope }
    },
    {
      Sid    = "TalosDenySessionDocumentChanges"
      Effect = "Deny"
      Action = ["ssm:CreateDocument", "ssm:DeleteDocument", "ssm:ModifyDocumentPermission", "ssm:UpdateDocument", "ssm:UpdateDocumentDefaultVersion"]
      Resource = [for name in setunion(
        ["${var.access.cluster_name}-kube-forward", "${var.access.cluster_name}-talos-forward", coalesce(var.access.kube_document_name, "${var.access.cluster_name}-kube-forward")],
        var.access.recovery_document_names,
      ) : "${local.ssm_arn}:document/${name}"]
      Condition = { StringEquals = local.regional_scope }
    },
    {
      Sid      = "TalosDenyRunCommandOnHosts"
      Effect   = "Deny"
      Action   = "ssm:SendCommand"
      Resource = local.protected_hosts
    },
    {
      # These operations authorize a session or workflow rather than the target instance.
      Sid    = "TalosDenyAlternateSSMDispatch"
      Effect = "Deny"
      Action = [
        "ssm:ResumeSession",
        "ssm:CreateAssociation", "ssm:CreateAssociationBatch", "ssm:UpdateAssociation", "ssm:StartAssociationsOnce",
        "ssm:StartAutomationExecution", "ssm:StartChangeRequestExecution",
        "ssm:RegisterTargetWithMaintenanceWindow", "ssm:RegisterTaskWithMaintenanceWindow",
        "ssm:UpdateMaintenanceWindowTarget", "ssm:UpdateMaintenanceWindowTask",
      ]
      Resource  = "*"
      Condition = { StringEquals = local.regional_scope }
    },
    {
      Sid      = "TalosAllowOwnSessionCleanup"
      Effect   = "Allow"
      Action   = ["ssm:TerminateSession", "ssmmessages:OpenDataChannel"]
      Resource = "${local.ssm_arn}:session/*"
      Condition = {
        StringEquals = merge(local.regional_scope, {
          "ssm:resourceTag/aws:ssmmessages:session-id" = local.session_owner
        })
      }
    },
    {
      Sid       = "TalosAllowSessionInventory"
      Effect    = "Allow"
      Action    = ["ssm:DescribeInstanceInformation", "ssm:DescribeSessions"]
      Resource  = "*"
      Condition = { StringEquals = local.regional_scope }
    },
    {
      Sid      = "TalosAllowCanaryWebIdentity"
      Effect   = "Allow"
      Action   = "sts:GetWebIdentityToken"
      Resource = "*"
      Condition = {
        StringEquals                = merge(local.regional_scope, { "sts:SigningAlgorithm" = "RS256" })
        "ForAllValues:StringEquals" = { "sts:IdentityTokenAudience" = var.access.audience }
        Null                        = { "sts:IdentityTokenAudience" = "false" }
        NumericLessThanEquals       = { "sts:DurationSeconds" = "300" }
      }
    },
    local.state_deny,
    {
      # EC2 does not expose which attribute is requested in this action's IAM context.
      Sid      = "TalosDenyControllerAttributeRead"
      Effect   = "Deny"
      Action   = "ec2:DescribeInstanceAttribute"
      Resource = "${local.instance_arn}/*"
      Condition = {
        StringEquals = local.regional_scope
        StringLike   = local.controller_names
      }
    },
    {
      Sid      = "TalosDenyControllerRename"
      Effect   = "Deny"
      Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
      Resource = "${local.instance_arn}/*"
      Condition = {
        StringEquals               = local.regional_scope
        StringLike                 = local.controller_names
        "ForAnyValue:StringEquals" = { "aws:TagKeys" = "Name" }
      }
    },
  ]

  billing_statements = [
    {
      Sid       = "TalosDenyBillingSSM"
      Effect    = "Deny"
      Action    = ["ssm:StartSession", "ssm:ResumeSession"]
      Resource  = "*"
      Condition = { StringEquals = local.regional_scope }
    },
    local.state_deny,
  ]
}

output "ordinary_policy_json" {
  value = jsonencode({ Version = "2012-10-17", Statement = local.ordinary_statements })
}

output "billing_policy_json" {
  value = jsonencode({ Version = "2012-10-17", Statement = local.billing_statements })
}
