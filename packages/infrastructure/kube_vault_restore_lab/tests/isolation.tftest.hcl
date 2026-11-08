mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-east-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "668112512252" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::668112512252:role/migration-test-only" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::668112512252:policy/migration-test-only" }
  }
}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "pf" {
  mock_data "pf_metadata" {
    defaults = { kube_cluster_name = "test-only" }
  }
  mock_data "pf_aws_tags" {
    defaults = { tags = {} }
  }
}

variables {
  image             = "example.invalid/synthetic@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  seal_key_arn      = "arn:aws:kms:us-east-2:668112512252:key/11111111-1111-1111-1111-111111111111"
  oidc_provider_arn = "arn:aws:iam::668112512252:oidc-provider/issuer.synthetic.test"
  oidc_issuer_url   = "https://issuer.synthetic.test"
  node_selector     = { "migration-test" = "true" }
}

run "default_is_stopped_and_scoped" {
  command = plan
  assert {
    condition     = kubernetes_resource_quota_v1.lab[0].spec[0].hard["requests.memory"] == "448Mi"
    error_message = "Test helpers and secondary instances must share an aggregate memory budget."
  }
  assert {
    condition     = tonumber(kubernetes_stateful_set_v1.server.spec[0].replicas) == 0
    error_message = "Installing the harness must not start a server."
  }
  assert {
    condition     = kubernetes_service_v1.server.spec[0].type == "ClusterIP"
    error_message = "The recovery API must remain private."
  }
  assert {
    condition     = !kubernetes_stateful_set_v1.server.spec[0].template[0].spec[0].automount_service_account_token
    error_message = "The restored process must not receive a Kubernetes API token."
  }
  assert {
    condition = (
      kubernetes_stateful_set_v1.server.spec[0].template[0].spec[0].security_context[0].run_as_non_root &&
      kubernetes_stateful_set_v1.server.spec[0].template[0].spec[0].container[0].security_context[0].run_as_non_root
    )
    error_message = "Explicit container non-root must not override the Pod-level restriction with the provider's false default."
  }
  assert {
    condition = length(local.iam_policy.Statement) == 1 && (
      toset(local.iam_policy.Statement[0].Action) == toset(["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"])
      ) && (
      toset(local.iam_policy.Statement[0].Resource) == toset([var.seal_key_arn])
    )
    error_message = "No wildcard, IAM, S3 or external-credential permissions may reach the restored lease manager."
  }
  assert {
    condition = alltrue([for rule in local.network_policy.spec.egress :
      !contains(keys(rule), "toEntities") && !contains(keys(rule), "toCIDR") && !contains(keys(rule), "toCIDRSet")
      ]) && alltrue([for rule in slice(local.network_policy.spec.egress, 1, 3) :
      rule.toFQDNs[0].matchName == rule.toPorts[0].serverNames[0] &&
      contains(["kms.us-east-2.amazonaws.com", "sts.us-east-2.amazonaws.com"], rule.toFQDNs[0].matchName)
    ])
    error_message = "Data-plane egress must use exact KMS/STS hostnames and SNI, without broad destination exceptions."
  }
  assert {
    condition     = length(regexall("(?m)^\\s*retry_join|^\\s*service_registration", local.configuration)) == 0
    error_message = "A clone must not join production Raft or register against production Kubernetes Services."
  }
  assert {
    condition     = strcontains(local.configuration, "cluster_addr = \"https://127.0.0.1:8201\"")
    error_message = "Singleton Raft startup still requires an explicit isolated cluster address."
  }
}

run "secondary_instance_does_not_coown_namespace" {
  command = plan
  variables { create_namespace = false }
  assert {
    condition     = length(kubernetes_namespace_v1.lab) == 0 && length(kubernetes_resource_quota_v1.lab) == 0
    error_message = "There must be exactly one namespace and quota owner."
  }
}

run "reject_unverified_start" {
  command = plan
  variables { server_enabled = true }
  expect_failures = [kubernetes_stateful_set_v1.server]
}

run "reject_production_namespace" {
  command = plan
  variables { namespace = "vault" }
  expect_failures = [var.namespace]
}

run "reject_missing_openbao_plugins" {
  command = plan
  variables { engine = "openbao" }
  expect_failures = [kubernetes_stateful_set_v1.server]
}

run "openbao_requires_local_hash_pinned_plugins" {
  command = plan
  variables {
    engine = "openbao"
    plugins = [
      { type = "kms", name = "awskms", command = "kms-test", version = "v0.1.1", sha256sum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
      { type = "secret", name = "aws", command = "aws-test", version = "v0.3.3", sha256sum = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" }
    ]
  }
  assert {
    condition     = strcontains(local.configuration, "plugin_auto_download = false") && strcontains(local.configuration, "sha256sum =")
    error_message = "Restored startup must not require opening registry network access."
  }
}
