run "only_kubernetes_on_the_selected_jump_host" {
  command = plan

  variables {
    access = {
      account_id       = "123456789012"
      region           = "us-east-2"
      cluster_name     = "operator-canary"
      jump_host_id     = "i-01234567890123456"
      nat_host_ids     = ["i-01234567890123457"]
      audience         = "talos-canary-audience"
      state_object_arn = "arn:aws:s3:::test-state/canary/*"
    }
  }

  assert {
    condition = contains(jsondecode(output.ordinary_policy_json).Statement, {
      Sid         = "TalosDenyAlternateSessions"
      Effect      = "Deny"
      Action      = "ssm:StartSession"
      NotResource = ["arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123456", "arn:aws:ssm:us-east-2:123456789012:document/operator-canary-kube-forward"]
      Condition = { StringEquals = {
        "aws:PrincipalAccount" = "123456789012"
        "aws:RequestedRegion"  = "us-east-2"
      } }
    })
    error_message = "Ordinary roles must deny every other StartSession resource, even with an existing Allow."
  }

  assert {
    condition = alltrue([
      one([for s in jsondecode(output.ordinary_policy_json).Statement : s.Condition.Bool["ssm:SessionDocumentAccessCheck"] if s.Sid == "TalosDenyFailedDocumentCheck"]) == "false",
      one([for s in jsondecode(output.ordinary_policy_json).Statement : s.Condition.BoolIfExists["ssm:SessionDocumentAccessCheck"] if s.Sid == "TalosAllowKubernetesTarget"]) == "true",
    ])
    error_message = "A failed document check must deny the request. An absent check must leave the exact host and document ARN rules in force."
  }

  assert {
    condition = contains(one([
      for s in jsondecode(output.ordinary_policy_json).Statement : s.Resource if s.Sid == "TalosDenyRunCommandOnHosts"
    ]), "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123457")
    error_message = "Ordinary roles must be denied Run Command on the NAT."
  }

  assert {
    condition = alltrue([
      one([for s in jsondecode(output.ordinary_policy_json).Statement : s.Action if s.Sid == "TalosDenyControllerAttributeRead"]) == "ec2:DescribeInstanceAttribute",
      one([for s in jsondecode(output.ordinary_policy_json).Statement : s.Resource if s.Sid == "TalosDenyCanaryState"]) == "arn:aws:s3:::test-state/canary/*",
      one([for s in jsondecode(output.ordinary_policy_json).Statement : s.Condition["ForAllValues:StringEquals"]["sts:IdentityTokenAudience"] if s.Sid == "TalosAllowCanaryWebIdentity"]) == "talos-canary-audience",
      alltrue([for s in jsondecode(output.billing_policy_json).Statement : s.Effect == "Deny"]),
    ])
    error_message = "The ordinary roles must protect state and controller PKI, and BillingAdmin must receive no access."
  }
}

run "either_approved_host_can_forward_only_the_selected_kubernetes_document" {
  command = plan

  variables {
    access = {
      account_id               = "123456789012"
      region                   = "us-east-2"
      cluster_name             = "operator-canary"
      jump_host_id             = "i-01234567890123456"
      additional_jump_host_ids = ["i-01234567890123458"]
      kube_document_name       = "operator-canary-private-kube"
      recovery_document_names  = ["operator-canary-talos-a", "operator-canary-talos-b", "operator-canary-bootstrap-kube"]
      nat_host_ids             = ["i-01234567890123457"]
      audience                 = "talos-canary-audience"
      state_object_arn         = "arn:aws:s3:::test-state/canary/*"
    }
  }

  assert {
    condition = contains(jsondecode(output.ordinary_policy_json).Statement, {
      Sid    = "TalosDenyAlternateSessions"
      Effect = "Deny"
      Action = "ssm:StartSession"
      NotResource = [
        "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123456",
        "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123458",
        "arn:aws:ssm:us-east-2:123456789012:document/operator-canary-private-kube",
      ]
      Condition = { StringEquals = {
        "aws:PrincipalAccount" = "123456789012"
        "aws:RequestedRegion"  = "us-east-2"
      } }
    })
    error_message = "Deny unapproved instances and documents, including NAT, AWS generic forwarding, shell and all recovery documents."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(output.ordinary_policy_json).Statement :
      toset(statement.Resource) == toset([
        "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123456",
        "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123458",
      ])
      if contains(["TalosDenyFailedDocumentCheck", "TalosAllowKubernetesTarget"], statement.Sid)
      ]) && contains(jsondecode(output.ordinary_policy_json).Statement, {
      Sid      = "TalosAllowKubernetesDocument"
      Effect   = "Allow"
      Action   = "ssm:StartSession"
      Resource = "arn:aws:ssm:us-east-2:123456789012:document/operator-canary-private-kube"
      Condition = { StringEquals = {
        "aws:PrincipalAccount" = "123456789012"
        "aws:RequestedRegion"  = "us-east-2"
      } }
    })
    error_message = "Allow the selected Kubernetes document on both hosts and deny a failed document check on either."
  }

  assert {
    condition = (
      toset(one([
        for statement in jsondecode(output.ordinary_policy_json).Statement : statement.Resource
        if statement.Sid == "TalosDenyRunCommandOnHosts" && statement.Effect == "Deny" && statement.Action == "ssm:SendCommand"
        ])) == toset([
        "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123456",
        "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123457",
        "arn:aws:ec2:us-east-2:123456789012:instance/i-01234567890123458",
      ])
      && toset(one([
        for statement in jsondecode(output.ordinary_policy_json).Statement : statement.Resource
        if statement.Sid == "TalosDenySessionDocumentChanges" && statement.Effect == "Deny"
        ])) == toset([
        for name in [
          "operator-canary-private-kube", "operator-canary-kube-forward", "operator-canary-talos-forward",
          "operator-canary-talos-a", "operator-canary-talos-b", "operator-canary-bootstrap-kube",
        ] : "arn:aws:ssm:us-east-2:123456789012:document/${name}"
      ])
    )
    error_message = "Protect both jump hosts and the NAT from Run Command and protect every managed or legacy forwarding document from changes."
  }
}

run "reject_nat_as_an_ordinary_jump_host" {
  command = plan

  variables {
    access = {
      account_id               = "123456789012"
      region                   = "us-east-2"
      cluster_name             = "operator-canary"
      jump_host_id             = "i-01234567890123456"
      additional_jump_host_ids = ["i-01234567890123457"]
      nat_host_ids             = ["i-01234567890123457"]
      audience                 = "talos-canary-audience"
      state_object_arn         = "arn:aws:s3:::test-state/canary/*"
    }
  }

  expect_failures = [var.access]
}
