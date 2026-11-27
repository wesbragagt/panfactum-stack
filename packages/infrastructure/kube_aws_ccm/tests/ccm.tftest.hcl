mock_provider "aws" {
  mock_data "aws_region" { defaults = { region = "us-east-2" } }
  mock_data "aws_instance" { defaults = { subnet_id = "subnet-0000000000000000a" } }
  mock_data "aws_subnet" { defaults = { availability_zone = "us-east-2b", vpc_id = "vpc-00000000" } }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "pf" {}

override_module {
  target = module.aws_permissions
  outputs = {
    role_arn                    = "arn:aws:iam::123456789012:role/ccm"
    service_account_annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/ccm" }
  }
}

variables {
  cluster = {
    type              = "talos"
    name              = "test"
    endpoint          = "https://api.test.internal:6443"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/test"
    oidc_issuer_url   = "https://test.s3.us-east-2.amazonaws.com"
  }
  controller_provider_ids = {
    "10.0.2.10" = "aws:///us-east-2c/i-00000000000000002"
    "10.0.1.10" = "aws:///us-east-2b/i-00000000000000001"
  }
}

run "plans_from_the_aws_kube_talos_outputs" {
  command = plan

  assert {
    condition     = data.aws_instance.controller.instance_id == "i-00000000000000001"
    error_message = "Topology must come from the controller with the lowest private IP."
  }
  assert {
    condition     = kubernetes_config_map_v1.cloud.data["cloud.conf"] == "[Global]\nRegion=us-east-2\nZone=us-east-2b\nVPC=vpc-00000000\nSubnetID=subnet-0000000000000000a\nKubernetesClusterID=test\n"
    error_message = "cloud.conf must carry the derived region, zone, VPC, subnet and cluster ID."
  }
  assert {
    condition     = yamldecode(helm_release.ccm.values[0]).image.tag == "v1.36.1" && yamldecode(helm_release.ccm.values[0]).hostNetworking
    error_message = "CCM must default to the Kubernetes 1.36 image on the host network."
  }
}

run "patches_each_controller_before_the_release" {
  command = plan

  assert {
    condition = (
      keys(terraform_data.controller_provider_id) == ["10.0.1.10", "10.0.2.10"] &&
      terraform_data.controller_provider_id["10.0.2.10"].triggers_replace.provider_id == "aws:///us-east-2c/i-00000000000000002"
    )
    error_message = "Each controller needs its own provider ID patch."
  }
}

run "rejects_empty_provider_ids" {
  command = plan
  variables {
    controller_provider_ids = {}
  }
  expect_failures = [var.controller_provider_ids]
}

run "rejects_malformed_provider_id" {
  command = plan
  variables {
    controller_provider_ids = { "10.0.1.10" = "i-00000000000000001" }
  }
  expect_failures = [var.controller_provider_ids]
}
