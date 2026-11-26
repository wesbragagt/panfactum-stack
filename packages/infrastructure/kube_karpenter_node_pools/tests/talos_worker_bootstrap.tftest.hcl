mock_provider "aws" {
  override_data {
    target = data.aws_subnet.node_subnets
    values = { id = "subnet-1" }
  }
}
mock_provider "kubectl" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "pf" {
  mock_data "pf_kube_labels" {
    defaults = { labels = { "panfactum.com/module" = "kube_karpenter_node_pools" } }
  }
  mock_data "pf_metadata" {
    defaults = { kube_cluster_name = "test" }
  }
}

variables {
  node_instance_profile = "worker"
  talos_launch = {
    ami_id            = "ami-talos"
    vpc_id            = "vpc-1"
    security_group_id = "sg-1"
    subnets           = ["PRIVATE_A"]
  }
  talos_worker_bootstrap = {
    cluster_name       = "test"
    cluster_endpoint   = "https://api.example:6443"
    talos_version      = "v1.14.6"
    kubernetes_version = "1.36.5"
    installer_image    = "example.test/installer:v1.14.6"
    pod_subnets        = ["10.244.0.0/16"]
    service_subnets    = ["10.113.0.0/16"]
    secrets_bundle = {
      certs = {
        os  = { crt = "Zml4dHVyZSBPUyBDQQ==" }
        k8s = { crt = "Zml4dHVyZSBLdWJlcm5ldGVzIENBCg==" }
      }
      cluster    = { id = "fixture-cluster-id", secret = "fixture-cluster-secret" }
      secrets    = { bootstraptoken = "fixture-bootstrap-token" }
      trustdinfo = { token = "fixture-trust-token" }
    }
  }
}

run "generate_talos_worker_config" {
  command = apply

  assert {
    condition = alltrue([
      for node_class in kubectl_manifest.talos_node_class :
      yamldecode(node_class.yaml_body).spec.amiSelectorTerms == [{ id = "ami-talos" }] &&
      yamldecode(node_class.yaml_body).spec.subnetSelectorTerms == [{ id = "subnet-1" }] &&
      yamldecode(node_class.yaml_body).spec.securityGroupSelectorTerms == [{ id = "sg-1" }] &&
      yamldecode(node_class.yaml_body).spec.instanceProfile == "worker"
    ])
    error_message = "The typed Talos inputs must retain the original AMI, subnet, security group, and profile."
  }

  assert {
    # NOTE: These hashes come from NodeClass user data rendered using the v0.12.0 provider and synthetic join values.
    condition = (
      sha256(local.talos_user_data["default"]) == "b1e64d4ffda0bdcc01e5271001f8c0d787a62783f6ed2a62bac508c69ff539f6" &&
      sha256(local.talos_user_data["spot"]) == "f84321c1797b779ee43c50c1a317d13aeb774cc0eb968ffc763467ce4902317b" &&
      sha256(local.talos_user_data["burstable"]) == "f84321c1797b779ee43c50c1a317d13aeb774cc0eb968ffc763467ce4902317b"
    )
    error_message = "Worker-only generation must preserve each existing NodeClass's user data."
  }
}

run "reject_missing_talos_installer" {
  command = plan

  variables {
    talos_worker_bootstrap = {
      cluster_name       = "test"
      cluster_endpoint   = "https://api.example:6443"
      talos_version      = "v1.14.6"
      kubernetes_version = "1.36.5"
      pod_subnets        = ["10.244.0.0/16"]
      service_subnets    = ["10.113.0.0/16"]
      secrets_bundle = {
        certs      = { os = { crt = "" }, k8s = { crt = "" } }
        cluster    = { id = "", secret = "" }
        secrets    = { bootstraptoken = "" }
        trustdinfo = { token = "" }
      }
    }
  }

  expect_failures = [var.talos_worker_bootstrap]
}

run "reject_mismatched_talos_installer" {
  command = plan

  variables {
    talos_worker_bootstrap = {
      cluster_name       = "test"
      cluster_endpoint   = "https://api.example:6443"
      talos_version      = "v1.14.6"
      kubernetes_version = "1.36.5"
      installer_image    = "example.test/installer:v1.14.0"
      pod_subnets        = ["10.244.0.0/16"]
      service_subnets    = ["10.113.0.0/16"]
      secrets_bundle = {
        certs      = { os = { crt = "" }, k8s = { crt = "" } }
        cluster    = { id = "", secret = "" }
        secrets    = { bootstraptoken = "" }
        trustdinfo = { token = "" }
      }
    }
  }

  expect_failures = [var.talos_worker_bootstrap]
}
