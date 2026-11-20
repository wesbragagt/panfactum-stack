// Guards that cluster_type = "eks" renders byte-for-byte as before the Talos pool set.
// Hashes were captured from the pre-change module with the same fixed mock values.
mock_provider "aws" {
  override_data {
    target = data.aws_ami.arm64_ami
    values = { id = "ami-arm64" }
  }
  override_data {
    target = data.aws_ami.amd64_ami
    values = { id = "ami-amd64" }
  }
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

override_resource {
  target = random_id.default_node_class_name
  values = { hex = "default-00000001" }
}
override_resource {
  target = random_id.spot_node_class_name
  values = { hex = "spot-00000002" }
}
override_resource {
  target = random_id.burstable_node_class_name
  values = { hex = "burstable-00000003" }
}
override_resource {
  target = random_id.burstable_node_pool_name
  values = { hex = "burstable-00000004" }
}
override_resource {
  target = random_id.burstable_arm_node_pool_name
  values = { hex = "burstable-arm-00000005" }
}
override_resource {
  target = random_id.spot_node_pool_name
  values = { hex = "spot-00000006" }
}
override_resource {
  target = random_id.spot_arm_node_pool_name
  values = { hex = "spot-arm-00000007" }
}
override_resource {
  target = random_id.on_demand_arm_node_pool_name
  values = { hex = "on-demand-arm-00000008" }
}
override_resource {
  target = random_id.on_demand_node_pool_name
  values = { hex = "on-demand-00000009" }
}
override_resource {
  target = kubectl_manifest.default_node_class
  values = { name = "default-00000001" }
}
override_resource {
  target = kubectl_manifest.spot_node_class
  values = { name = "spot-00000002" }
}
override_resource {
  target = kubectl_manifest.burstable_node_class
  values = { name = "burstable-00000003" }
}

variables {
  cluster_endpoint       = "https://api.example:443"
  cluster_ca_data        = "Q0E="
  cluster_dns_service_ip = "172.20.0.10"
  node_instance_profile  = "worker"
  node_vpc_id            = "vpc-1"
  node_subnets           = ["PRIVATE_A"]
  node_security_group_id = "sg-1"
}

run "eks_renders_as_before" {
  command = apply

  assert {
    condition = {
      default_node_class      = sha256(kubectl_manifest.default_node_class[0].yaml_body)
      spot_node_class         = sha256(kubectl_manifest.spot_node_class[0].yaml_body)
      burstable_node_class    = sha256(kubectl_manifest.burstable_node_class[0].yaml_body)
      burstable_node_pool     = sha256(kubectl_manifest.burstable_node_pool[0].yaml_body)
      wf_burstable_node_pool  = sha256(kubectl_manifest.wf_burstable_node_pool[0].yaml_body)
      burstable_arm_node_pool = sha256(kubectl_manifest.burstable_arm_node_pool[0].yaml_body)
      wf_burstable_arm_pool   = sha256(kubectl_manifest.wf_burstable_arm_node_pool[0].yaml_body)
      spot_node_pool          = sha256(kubectl_manifest.spot_node_pool[0].yaml_body)
      wf_spot_node_pool       = sha256(kubectl_manifest.wf_spot_node_pool[0].yaml_body)
      spot_arm_node_pool      = sha256(kubectl_manifest.spot_arm_node_pool[0].yaml_body)
      wf_spot_arm_node_pool   = sha256(kubectl_manifest.wf_spot_arm_node_pool[0].yaml_body)
      on_demand_arm_node_pool = sha256(kubectl_manifest.on_demand_arm_node_pool[0].yaml_body)
      wf_on_demand_arm_pool   = sha256(kubectl_manifest.wf_on_demand_arm_node_pool[0].yaml_body)
      on_demand_node_pool     = sha256(kubectl_manifest.on_demand_node_pool[0].yaml_body)
      wf_on_demand_node_pool  = sha256(kubectl_manifest.wf_on_demand_node_pool[0].yaml_body)
      } == {
      burstable_arm_node_pool = "ba10274cca98511604af2d22b37cf6c850f7a24020f1e9ff891fad9ef9f7a51d"
      burstable_node_class    = "3006ab1af52ae088f7953899dd915e31d2a5c44cf20894e31b414a859debf0ab"
      burstable_node_pool     = "2b5d5cdbbb5118b8eec4da07b36ebada7288abdcee403e0c660f6a9871b96d29"
      default_node_class      = "28393d15bd4771dae6c132835a1a1e56bdea91674e4672954c0e8620dc00719c"
      on_demand_arm_node_pool = "59880e9c986c04c6054f90e1f716026bce816bd1a078cd74d2be1fe3251a33d6"
      on_demand_node_pool     = "bed2323cf9b3380653561c59b9060ab22261fe1813c7ddad4b4ee4d201d922e3"
      spot_arm_node_pool      = "9f53608172d2fd43ad664321d7ab1893995888d4702b4f3aa8bbcba8c7419f94"
      spot_node_class         = "e36f20bfbd43def0f33ea12bee57a7e710c943897df9dbc12b5f6e9119237a6f"
      spot_node_pool          = "daa9468c5d4330ba39f068ae5e7e21848eb25dba25257237f34f202595de5eec"
      wf_burstable_arm_pool   = "edcc4526bac0fc4769b09cbc0954b9dbb79ac9b1cca863263e4bf9bb398349e8"
      wf_burstable_node_pool  = "31e10e040a81ee87a26633ae98f80ac7bddb13dec728cb473b3c908d7feeccfc"
      wf_on_demand_arm_pool   = "96711873d6dc35f5f334e3ef42a95507ae6d4156a5c75efa66997f533dc551dc"
      wf_on_demand_node_pool  = "fa8a8e7ef132f220b7bcbddd351c9406288d1ffd0e7da033f460e958b05e2e0a"
      wf_spot_arm_node_pool   = "cbcced1ac67df460190029960481038b11d710eef7d6dbbe59c56a1b97df5049"
      wf_spot_node_pool       = "c86a6dd75f40a28f1b5f663a0a4c3540d41c98e2e0dbc5efc10bd2a25ef4f12a"
    }
    error_message = "EKS manifests changed: ${nonsensitive(jsonencode({
      default_node_class      = sha256(kubectl_manifest.default_node_class[0].yaml_body)
      spot_node_class         = sha256(kubectl_manifest.spot_node_class[0].yaml_body)
      burstable_node_class    = sha256(kubectl_manifest.burstable_node_class[0].yaml_body)
      burstable_node_pool     = sha256(kubectl_manifest.burstable_node_pool[0].yaml_body)
      wf_burstable_node_pool  = sha256(kubectl_manifest.wf_burstable_node_pool[0].yaml_body)
      burstable_arm_node_pool = sha256(kubectl_manifest.burstable_arm_node_pool[0].yaml_body)
      wf_burstable_arm_pool   = sha256(kubectl_manifest.wf_burstable_arm_node_pool[0].yaml_body)
      spot_node_pool          = sha256(kubectl_manifest.spot_node_pool[0].yaml_body)
      wf_spot_node_pool       = sha256(kubectl_manifest.wf_spot_node_pool[0].yaml_body)
      spot_arm_node_pool      = sha256(kubectl_manifest.spot_arm_node_pool[0].yaml_body)
      wf_spot_arm_node_pool   = sha256(kubectl_manifest.wf_spot_arm_node_pool[0].yaml_body)
      on_demand_arm_node_pool = sha256(kubectl_manifest.on_demand_arm_node_pool[0].yaml_body)
      wf_on_demand_arm_pool   = sha256(kubectl_manifest.wf_on_demand_arm_node_pool[0].yaml_body)
      on_demand_node_pool     = sha256(kubectl_manifest.on_demand_node_pool[0].yaml_body)
      wf_on_demand_node_pool  = sha256(kubectl_manifest.wf_on_demand_node_pool[0].yaml_body)
    }))}"
  }

  assert {
    condition     = length(kubectl_manifest.talos_node_class) == 0
    error_message = "EKS must not create Talos node classes."
  }
}
