mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { region = "us-east-2", name = "us-east-2" } }
  mock_data "aws_partition" { defaults = { partition = "aws", dns_suffix = "amazonaws.com" } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }
}

variables {
  name_prefix  = "migration-test"
  cluster_name = "migration-test"
}

run "default_preserves_scope" {
  command = plan
  assert {
    condition     = length(data.aws_iam_policy_document.controller_read.statement) == 1
    error_message = "Default controller reads must remain unchanged."
  }
}

run "exact_repository_read_only" {
  command = plan
  variables {
    controller_additional_ecr_repositories = ["homelab-migrations/openbao"]
  }
  assert {
    condition = alltrue([for statement in data.aws_iam_policy_document.controller_read.statement :
      statement.sid != "AdditionalExactRepositoryReads" || (
        toset(statement.resources) == toset(["arn:aws:ecr:us-east-2:123456789012:repository/homelab-migrations/openbao"]) &&
        toset(statement.actions) == toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"])
      )
    ]) && length(data.aws_iam_policy_document.controller_read.statement) == 2
    error_message = "Only exact same-account/region repository reads may be added."
  }
  assert {
    condition     = length(aws_iam_role_policy.cache_import) == 0
    error_message = "Extra reads must never opt into cache import/create permissions."
  }
}

run "wildcard_rejected" {
  command = plan
  variables {
    controller_additional_ecr_repositories = ["homelab-migrations/*"]
  }
  expect_failures = [var.controller_additional_ecr_repositories]
}

# aws_kube_talos sets this profile on each controller's aws_instance.iam_instance_profile.
run "controller_profile_enabled" {
  command = plan
  variables {
    controller_instance_profile_enabled = true
  }
  assert {
    condition     = length(aws_iam_instance_profile.controller) == 1 && length(aws_iam_role_policy.controller_read) == 1
    error_message = "controller_instance_profile_enabled must create the controller profile and its ECR read policy."
  }
}

run "no_controller_profile_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_instance_profile.controller) == 0
    error_message = "The controller profile is opt-in."
  }
}
