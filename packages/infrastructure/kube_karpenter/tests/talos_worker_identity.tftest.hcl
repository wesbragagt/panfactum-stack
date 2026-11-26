provider "aws" {
  region                      = "us-east-2"
  access_key                  = "fixture"
  secret_key                  = "fixture"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "pf" {
  mock_data "pf_kube_labels" {
    defaults = { labels = {} }
  }
  mock_data "pf_aws_tags" {
    defaults = { tags = {} }
  }
}

override_data {
  target = data.aws_caller_identity.main
  values = { account_id = "123456789012" }
}

override_data {
  target = module.aws_permissions.data.aws_caller_identity.main
  values = { account_id = "123456789012" }
}

override_resource {
  target = aws_sqs_queue.karpenter
  values = { arn = "arn:aws:sqs:us-east-2:123456789012:test-karpenter" }
}

variables {
  cluster_name            = "test"
  cluster_endpoint        = "https://api.example.test:6443"
  oidc_provider_arn       = "arn:aws:iam::123456789012:oidc-provider/issuer.example.test"
  oidc_issuer_url         = "https://issuer.example.test"
  ip_restrictions_enabled = false
}

run "talos_owns_fixed_worker_identity" {
  command = plan

  variables {
    talos_worker_identity = { ecr_cache_prefixes = ["docker-hub"] }
  }

  override_resource {
    target = aws_iam_role.talos_worker[0]
    values = {
      arn  = "arn:aws:iam::123456789012:role/test-worker"
      name = "test-worker"
      id   = "test-worker"
    }
  }

  override_resource {
    target = aws_iam_instance_profile.talos_worker[0]
    values = {
      arn  = "arn:aws:iam::123456789012:instance-profile/test-worker"
      name = "test-worker"
    }
  }

  assert {
    condition     = output.node_instance_profile == "test-worker" && length(aws_iam_role_policy.talos_worker_ecr_read) == 1 && length(aws_iam_role_policy.talos_worker_cache_import) == 1
    error_message = "The node pools must receive the fixed worker profile with both requested ECR policies."
  }

  assert {
    condition     = !local.manage_instance_profiles_enabled && local.worker_instance_profile_arn == "arn:aws:iam::123456789012:instance-profile/test-worker"
    error_message = "Karpenter must use the fixed worker profile without creating profiles itself."
  }

  assert {
    condition = toset(flatten([
      for statement in jsondecode(data.aws_iam_policy_document.talos_worker_cache_import[0].json).Statement :
      [statement.Resource]
    ])) == toset(["arn:aws:ecr:us-east-2:123456789012:repository/docker-hub/*"])
    error_message = "The optional worker cache policy must be scoped to its configured prefix."
  }
}

run "empty_talos_settings_use_the_baseline_worker_policy" {
  command = plan

  variables {
    talos_worker_identity = {}
  }

  assert {
    condition     = length(aws_iam_instance_profile.talos_worker) == 1 && length(aws_iam_role_policy.talos_worker_ecr_read) == 1 && length(aws_iam_role_policy.talos_worker_cache_import) == 0
    error_message = "Empty Talos settings must create a worker profile with only the baseline ECR policy."
  }
}

run "external_role_keeps_default_profile_management" {
  command = plan

  variables {
    node_role_arn = "arn:aws:iam::123456789012:role/eks-worker"
  }

  assert {
    condition     = length(aws_iam_role.talos_worker) == 0 && output.node_instance_profile == null
    error_message = "An external worker role must keep the existing identity mode."
  }

  assert {
    condition     = local.manage_instance_profiles_enabled && local.worker_instance_profile_arn == null
    error_message = "Karpenter must still manage profiles by default for callers with an external role."
  }

  assert {
    condition     = helm_release.karpenter.version == "1.10.0" && helm_release.karpenter_crds.version == "1.10.0" && length([for s in data.aws_iam_policy_document.karpenter.statement : s if s.sid == "AllowKarpenter115RegionalReads"]) == 0
    error_message = "Legacy callers must retain the 1.10 chart and existing IAM policy."
  }
}

run "cluster_talos_enables_worker_identity" {
  command = plan

  variables {
    cluster_name      = null
    cluster_endpoint  = null
    oidc_provider_arn = null
    oidc_issuer_url   = null
    cluster = {
      type              = "talos"
      name              = "test"
      endpoint          = "https://api.example.test:6443"
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/issuer.example.test"
      oidc_issuer_url   = "https://issuer.example.test"
    }
  }

  assert {
    condition     = local.talos_worker_identity_enabled && length(aws_iam_role.talos_worker) == 1 && length(aws_iam_instance_profile.talos_worker) == 1 && length(aws_iam_role_policy.talos_worker_cache_import) == 0
    error_message = "A Talos cluster must enable the fixed worker identity with baseline permissions."
  }

  assert {
    condition     = local.cluster_name == "test" && local.cluster_endpoint == "https://api.example.test:6443"
    error_message = "The Talos cluster name and endpoint must reach Karpenter."
  }

  assert {
    condition     = helm_release.karpenter.version == "1.15.1" && helm_release.karpenter_crds.version == "1.15.1"
    error_message = "A Talos cluster must default to the tested Karpenter chart."
  }

  assert {
    condition = one([for s in data.aws_iam_policy_document.karpenter.statement : s if s.sid == "AllowKarpenter115RegionalReads"]).actions == toset([
      "ec2:DescribeCapacityReservations", "ec2:DescribeInstanceStatus", "ec2:DescribePlacementGroups"
    ]) && toset(one(one([for s in data.aws_iam_policy_document.karpenter.statement : s if s.sid == "AllowKarpenter115RegionalReads"]).condition).values) == toset(["us-east-2"])
    error_message = "The Talos default must preserve the existing region-scoped read statement."
  }
}

run "cluster_talos_accepts_identity_overrides" {
  command = plan

  variables {
    cluster_name           = null
    cluster_endpoint       = null
    oidc_provider_arn      = null
    oidc_issuer_url        = null
    karpenter_helm_version = "1.15.0"
    cluster = {
      type              = "talos"
      name              = "test"
      endpoint          = "https://api.example.test:6443"
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/issuer.example.test"
      oidc_issuer_url   = "https://issuer.example.test"
    }
    talos_worker_identity = {
      name_prefix        = "custom"
      ecr_cache_prefixes = ["docker-hub"]
    }
  }

  assert {
    condition     = aws_iam_role.talos_worker[0].name_prefix == "custom-worker-" && length(aws_iam_role_policy.talos_worker_cache_import) == 1
    error_message = "Talos worker identity overrides must retain the configured prefix and cache access."
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.karpenter.statement : s if s.sid == "AllowKarpenter115RegionalReads"]) == 1
    error_message = "Overriding the chart patch version within Karpenter 1.15 must retain the regional reads."
  }
}

run "cluster_talos_preserves_policy_override" {
  command = plan
  variables {
    cluster_name      = null
    cluster_endpoint  = null
    oidc_provider_arn = null
    oidc_issuer_url   = null
    cluster = {
      type              = "talos"
      name              = "test"
      endpoint          = "https://api.example.test:6443"
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/issuer.example.test"
      oidc_issuer_url   = "https://issuer.example.test"
    }
    additional_controller_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = {
        Sid      = "AllowKarpenter115RegionalReads"
        Effect   = "Allow"
        Action   = ["ec2:DescribeCapacityReservations"]
        Resource = "*"
      }
    })
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.karpenter.statement : s if s.sid == "AllowKarpenter115RegionalReads"]) == 0 && data.aws_iam_policy_document.karpenter.source_policy_documents == tolist([var.additional_controller_policy_json])
    error_message = "An explicit statement with the same SID must retain its supplied permissions."
  }
}

run "cluster_talos_explicit_chart_version" {
  command = plan
  variables {
    cluster_name           = null
    cluster_endpoint       = null
    oidc_provider_arn      = null
    oidc_issuer_url        = null
    karpenter_helm_version = "1.14.0"
    cluster = {
      type              = "talos"
      name              = "test"
      endpoint          = "https://api.example.test:6443"
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/issuer.example.test"
      oidc_issuer_url   = "https://issuer.example.test"
    }
  }

  assert {
    condition     = helm_release.karpenter.version == "1.14.0" && helm_release.karpenter_crds.version == "1.14.0" && length([for s in data.aws_iam_policy_document.karpenter.statement : s if s.sid == "AllowKarpenter115RegionalReads"]) == 0
    error_message = "An explicit chart version outside 1.15 must be retained without the 1.15 policy default."
  }
}

run "cluster_rejects_duplicate_scalar_inputs" {
  command = plan

  variables {
    cluster = {
      type              = "talos"
      name              = "test"
      endpoint          = "https://api.example.test:6443"
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/issuer.example.test"
      oidc_issuer_url   = "https://issuer.example.test"
    }
  }
  expect_failures = [var.cluster]
}

run "cluster_rejects_external_worker_role" {
  command = plan

  variables {
    cluster_name      = null
    cluster_endpoint  = null
    oidc_provider_arn = null
    oidc_issuer_url   = null
    node_role_arn     = "arn:aws:iam::123456789012:role/external"
    cluster = {
      type              = "talos"
      name              = "test"
      endpoint          = "https://api.example.test:6443"
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/issuer.example.test"
      oidc_issuer_url   = "https://issuer.example.test"
    }
  }
  expect_failures = [var.node_role_arn]
}
