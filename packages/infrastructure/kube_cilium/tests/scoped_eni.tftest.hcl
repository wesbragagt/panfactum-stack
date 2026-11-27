mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_s3_bucket" {
    defaults = { bucket_regional_domain_name = "example-issuer.s3.us-east-2.amazonaws.com" }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      arn            = "arn:aws:iam::123456789012:oidc-provider/example-issuer.s3.us-east-2.amazonaws.com"
      client_id_list = ["sts.amazonaws.com"]
    }
  }
  mock_data "aws_security_group" {
    defaults = { id = "sg-nodes", vpc_id = "vpc-selected" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-private"] }
  }
  mock_data "aws_subnet" {
    defaults = { tags = { Name = "PRIVATE_A" } }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/cilium-operator" }
  }
}

mock_provider "pf" {
  mock_data "pf_metadata" {
    defaults = {
      environment       = "example"
      kube_cluster_name = "example-blue"
      kube_api_server   = "https://cluster.example"
    }
  }

  mock_data "pf_aws_tags" {
    defaults = { tags = {} }
  }

  mock_data "pf_kube_labels" {
    defaults = { labels = {} }
  }
}

mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  cluster    = { type = "talos", name = "example-blue" }
  sla_target = 2
}

run "talos_scoped_eni" {
  command = plan

  assert {
    condition = (
      data.aws_s3_bucket.oidc[0].bucket == "example-blue-oidc-123456789012" &&
      data.aws_iam_openid_connect_provider.talos[0].url == "https://example-issuer.s3.us-east-2.amazonaws.com" &&
      toset(tolist(data.aws_security_group.talos_nodes[0].filter)[0].values) == toset(["example-blue-nodes"]) &&
      toset(tolist(data.aws_subnets.talos_private[0].filter)[0].values) == toset(["vpc-selected"]) &&
      data.aws_subnets.talos_private[0].tags["panfactum.com/type"] == "private"
    )
    error_message = "Discovery must select the cluster's OIDC issuer, node security group and VPC private subnets."
  }

  assert {
    condition = (
      helm_release.cilium.name == "cilium" &&
      helm_release.cilium.namespace == "cilium" &&
      yamldecode(helm_release.cilium.values[0]).eni.nodeSpec.subnetIDs == ["subnet-private"] &&
      yamldecode(helm_release.cilium.values[0]).eni.nodeSpec.firstInterfaceIndex == 1 &&
      yamldecode(helm_release.cilium.values[0]).operator.replicas == 2 &&
      yamldecode(helm_release.cilium.values[0]).envoy.enabled == false &&
      yamldecode(helm_release.cilium.values[0]).l7Proxy == false &&
      length(helm_release.cilium.values) == 1
    )
    error_message = "The standard Talos render must retain sorted private subnets and the existing Helm values layout."
  }

  assert {
    condition = (
      aws_iam_role_policy.eni_scope[0].name == "blue-eni-scope" &&
      length(jsondecode(aws_iam_role_policy.eni_scope[0].policy).Statement) == 6 &&
      jsondecode(aws_iam_role_policy.eni_scope[0].policy).Statement[0].NotResource == [
        "arn:aws:ec2:us-east-2:123456789012:subnet/subnet-private",
        "arn:aws:ec2:us-east-2:123456789012:security-group/sg-nodes",
        "arn:aws:ec2:us-east-2:123456789012:network-interface/*",
      ] &&
      jsondecode(aws_iam_role_policy.eni_scope[0].policy).Statement[3].Condition.StringNotEquals == {
        "ec2:ResourceTag/kubernetes.io/cluster/example-blue" = "owned"
      }
    )
    error_message = "The role's inline policy must preserve the six statements and scope them to this cluster's ENIs."
  }
}

run "reject_subnets_outside_cluster_vpc" {
  command = plan

  variables {
    eni_subnet_ids_filter = ["subnet-other-vpc"]
  }

  expect_failures = [aws_iam_role_policy.eni_scope]
}

run "reject_conflicting_cluster_type" {
  command = plan

  variables {
    cluster_type = "eks"
  }

  expect_failures = [helm_release.cilium]
}

run "reject_mismatched_cluster_identity" {
  command = plan

  variables {
    cluster = { type = "talos", name = "example-green" }
  }

  expect_failures = [helm_release.cilium]
}
