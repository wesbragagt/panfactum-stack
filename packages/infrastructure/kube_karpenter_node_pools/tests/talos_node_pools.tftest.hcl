// Talos gets Panfactum's arm64 pool set on Talos node classes. amd64 pools stay EKS-only
// until aws_kube_talos supplies an amd64 Talos AMI.
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
  target = random_id.burstable_arm_node_pool_name
  values = { hex = "burstable-arm-00000005" }
}
override_resource {
  target = random_id.spot_arm_node_pool_name
  values = { hex = "spot-arm-00000007" }
}
override_resource {
  target = random_id.on_demand_arm_node_pool_name
  values = { hex = "on-demand-arm-00000008" }
}

variables {
  cluster_type           = "talos"
  cluster_endpoint       = "https://api.example:6443"
  cluster_ca_data        = ""
  cluster_dns_service_ip = "10.113.0.10"
  node_instance_profile  = "worker"
  node_vpc_id            = "vpc-1"
  node_subnets           = ["PRIVATE_A"]
  node_security_group_id = "sg-1"
  talos_ami_id           = "ami-talos"
  talos_worker_config    = <<-EOT
    apiVersion: v1alpha1
    kind: KubeNodeConfig
    registerWithFQDN: true
    labels:
      panfactum.com/class: worker
    taints:
      spot: true:NoSchedule
    ---
    apiVersion: v1alpha1
    kind: KubeletConfig
    extraArgs:
      cloud-provider: external
  EOT
}

run "talos_pool_set" {
  command = apply

  assert {
    condition = alltrue([for n in [
      length(kubectl_manifest.spot_node_pool), length(kubectl_manifest.wf_spot_node_pool),
      length(kubectl_manifest.burstable_node_pool), length(kubectl_manifest.wf_burstable_node_pool),
      length(kubectl_manifest.on_demand_node_pool), length(kubectl_manifest.wf_on_demand_node_pool),
    ] : n == 0])
    error_message = "amd64-only pools need an amd64 Talos AMI, which aws_kube_talos does not supply."
  }

  assert {
    condition = {
      for name, pool in {
        spot_arm         = kubectl_manifest.spot_arm_node_pool
        wf_spot_arm      = kubectl_manifest.wf_spot_arm_node_pool
        burstable_arm    = kubectl_manifest.burstable_arm_node_pool
        wf_burstable_arm = kubectl_manifest.wf_burstable_arm_node_pool
        on_demand_arm    = kubectl_manifest.on_demand_arm_node_pool
        wf_on_demand_arm = kubectl_manifest.wf_on_demand_arm_node_pool
        } : name => length(pool) == 0 ? null : {
        name           = yamldecode(pool[0].yaml_body).metadata.name
        weight         = yamldecode(pool[0].yaml_body).spec.weight
        class          = yamldecode(pool[0].yaml_body).spec.template.metadata.labels["panfactum.com/class"]
        workflow       = lookup(yamldecode(pool[0].yaml_body).spec.template.metadata.labels, "panfactum.com/workflow-only", "false")
        taints         = [for t in yamldecode(pool[0].yaml_body).spec.template.spec.taints : t.key]
        startup_taints = [for t in yamldecode(pool[0].yaml_body).spec.template.spec.startupTaints : t.key]
        capacity       = one([for r in yamldecode(pool[0].yaml_body).spec.template.spec.requirements : r.values if r.key == "karpenter.sh/capacity-type"])
        node_class     = yamldecode(pool[0].yaml_body).spec.template.spec.nodeClassRef.name
        grace          = yamldecode(pool[0].yaml_body).spec.template.spec.terminationGracePeriod
        expire         = yamldecode(pool[0].yaml_body).spec.template.spec.expireAfter
        disruption     = yamldecode(pool[0].yaml_body).spec.disruption
      }
      } == {
      spot_arm         = { name = "spot-arm-00000007", weight = 20, class = "spot", workflow = "false", taints = ["spot", "arm64"], startup_taints = ["node.cilium.io/agent-not-ready", "panfactum.com/linkerd-not-ready"], capacity = ["spot", "on-demand"], node_class = kubectl_manifest.talos_node_class["spot"].name, grace = "2m0s", expire = "24h", disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "10s", budgets = [] } }
      wf_spot_arm      = { name = "wf-spot-arm-00000007", weight = 20, class = "spot", workflow = "true", taints = ["spot", "arm64", "workflow"], startup_taints = ["node.cilium.io/agent-not-ready", "panfactum.com/linkerd-not-ready"], capacity = ["spot", "on-demand"], node_class = kubectl_manifest.talos_node_class["spot"].name, grace = "2m0s", expire = "24h", disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "10s", budgets = [] } }
      burstable_arm    = { name = "burstable-arm-00000005", weight = 30, class = "burstable", workflow = "false", taints = ["spot", "burstable", "arm64"], startup_taints = ["node.cilium.io/agent-not-ready", "panfactum.com/linkerd-not-ready"], capacity = ["spot", "on-demand"], node_class = kubectl_manifest.talos_node_class["burstable"].name, grace = "2m0s", expire = "24h", disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "10s", budgets = [] } }
      wf_burstable_arm = { name = "wf-burstable-arm-00000005", weight = 30, class = "burstable", workflow = "true", taints = ["spot", "burstable", "arm64", "workflow"], startup_taints = ["node.cilium.io/agent-not-ready", "panfactum.com/linkerd-not-ready"], capacity = ["spot", "on-demand"], node_class = kubectl_manifest.talos_node_class["burstable"].name, grace = "2m0s", expire = "24h", disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "10s", budgets = [] } }
      on_demand_arm    = { name = "on-demand-arm-00000008", weight = 10, class = "worker", workflow = "false", taints = ["arm64"], startup_taints = ["node.cilium.io/agent-not-ready", "panfactum.com/linkerd-not-ready"], capacity = ["on-demand"], node_class = kubectl_manifest.talos_node_class["default"].name, grace = "1h0m0s", expire = "24h", disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "10s", budgets = [] } }
      wf_on_demand_arm = { name = "wf-on-demand-arm-00000008", weight = 10, class = "worker", workflow = "true", taints = ["arm64", "workflow"], startup_taints = ["node.cilium.io/agent-not-ready", "panfactum.com/linkerd-not-ready"], capacity = ["on-demand"], node_class = kubectl_manifest.talos_node_class["default"].name, grace = "1h0m0s", expire = "24h", disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "10s", budgets = [] } }
    }
    error_message = "Talos arm64 pools must match the EKS pools except for the node class."
  }

  assert {
    condition = {
      for class, nc in kubectl_manifest.talos_node_class : class => {
        name      = yamldecode(nc.yaml_body).metadata.name
        ami       = yamldecode(nc.yaml_body).spec.amiSelectorTerms
        family    = yamldecode(nc.yaml_body).spec.amiFamily
        max_pods  = yamldecode(nc.yaml_body).spec.kubelet.maxPods
        sensitive = contains(nc.sensitive_fields, "spec.userData")
      }
      } == {
      default   = { name = "default-00000001", ami = [{ id = "ami-talos" }], family = "Custom", max_pods = 110, sensitive = true }
      spot      = { name = "spot-00000002", ami = [{ id = "ami-talos" }], family = "Custom", max_pods = 110, sensitive = true }
      burstable = { name = "burstable-00000003", ami = [{ id = "ami-talos" }], family = "Custom", max_pods = 110, sensitive = true }
    }
    error_message = "Talos needs default, spot and burstable Custom AMI node classes named like EKS."
  }

  // Karpenter applies each pool's labels and taints; the shared worker config must not override them.
  assert {
    condition = nonsensitive({
      for class, nc in kubectl_manifest.talos_node_class : class => {
        for doc in split("---\n", yamldecode(nc.yaml_body).spec.userData) : yamldecode(doc).kind => yamldecode(doc)
      }
      }) == {
      default = {
        KubeNodeConfig = { apiVersion = "v1alpha1", kind = "KubeNodeConfig", registerWithFQDN = true }
        KubeletConfig  = { apiVersion = "v1alpha1", kind = "KubeletConfig", extraArgs = { "cloud-provider" = "external" }, config = { registerWithTaints = [{ key = "karpenter.sh/unregistered", effect = "NoExecute" }], shutdownGracePeriod = "60m0s", shutdownGracePeriodCriticalPods = "30s" } }
      }
      spot = {
        KubeNodeConfig = { apiVersion = "v1alpha1", kind = "KubeNodeConfig", registerWithFQDN = true }
        KubeletConfig  = { apiVersion = "v1alpha1", kind = "KubeletConfig", extraArgs = { "cloud-provider" = "external" }, config = { registerWithTaints = [{ key = "karpenter.sh/unregistered", effect = "NoExecute" }], shutdownGracePeriod = "2m0s", shutdownGracePeriodCriticalPods = "30s" } }
      }
      burstable = {
        KubeNodeConfig = { apiVersion = "v1alpha1", kind = "KubeNodeConfig", registerWithFQDN = true }
        KubeletConfig  = { apiVersion = "v1alpha1", kind = "KubeletConfig", extraArgs = { "cloud-provider" = "external" }, config = { registerWithTaints = [{ key = "karpenter.sh/unregistered", effect = "NoExecute" }], shutdownGracePeriod = "2m0s", shutdownGracePeriodCriticalPods = "30s" } }
      }
    }
    error_message = "Talos userData must drop worker labels/taints and carry Panfactum's per-class shutdown grace periods."
  }
}

run "talos_rejects_private_keys" {
  command = plan

  variables {
    talos_worker_config = "kind: KubeletConfig\nkey: -----BEGIN EC PRIVATE KEY-----"
  }

  expect_failures = [kubectl_manifest.talos_node_class]
}
