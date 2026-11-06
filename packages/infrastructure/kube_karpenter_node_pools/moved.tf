// Preserve existing EKS addresses when adding the opt-in Talos path.
moved {
  from = random_id.default_node_class_name
  to   = random_id.default_node_class_name[0]
}

moved {
  from = kubectl_manifest.default_node_class
  to   = kubectl_manifest.default_node_class[0]
}

moved {
  from = random_id.spot_node_class_name
  to   = random_id.spot_node_class_name[0]
}

moved {
  from = kubectl_manifest.spot_node_class
  to   = kubectl_manifest.spot_node_class[0]
}

moved {
  from = random_id.burstable_node_class_name
  to   = random_id.burstable_node_class_name[0]
}

moved {
  from = kubectl_manifest.burstable_node_class
  to   = kubectl_manifest.burstable_node_class[0]
}

moved {
  from = random_id.burstable_node_pool_name
  to   = random_id.burstable_node_pool_name[0]
}

moved {
  from = kubectl_manifest.burstable_node_pool
  to   = kubectl_manifest.burstable_node_pool[0]
}

moved {
  from = kubectl_manifest.wf_burstable_node_pool
  to   = kubectl_manifest.wf_burstable_node_pool[0]
}

moved {
  from = random_id.burstable_arm_node_pool_name
  to   = random_id.burstable_arm_node_pool_name[0]
}

moved {
  from = kubectl_manifest.burstable_arm_node_pool
  to   = kubectl_manifest.burstable_arm_node_pool[0]
}

moved {
  from = kubectl_manifest.wf_burstable_arm_node_pool
  to   = kubectl_manifest.wf_burstable_arm_node_pool[0]
}

moved {
  from = random_id.spot_node_pool_name
  to   = random_id.spot_node_pool_name[0]
}

moved {
  from = kubectl_manifest.spot_node_pool
  to   = kubectl_manifest.spot_node_pool[0]
}

moved {
  from = kubectl_manifest.wf_spot_node_pool
  to   = kubectl_manifest.wf_spot_node_pool[0]
}

moved {
  from = random_id.spot_arm_node_pool_name
  to   = random_id.spot_arm_node_pool_name[0]
}

moved {
  from = kubectl_manifest.spot_arm_node_pool
  to   = kubectl_manifest.spot_arm_node_pool[0]
}

moved {
  from = kubectl_manifest.wf_spot_arm_node_pool
  to   = kubectl_manifest.wf_spot_arm_node_pool[0]
}

moved {
  from = random_id.on_demand_arm_node_pool_name
  to   = random_id.on_demand_arm_node_pool_name[0]
}

moved {
  from = kubectl_manifest.on_demand_arm_node_pool
  to   = kubectl_manifest.on_demand_arm_node_pool[0]
}

moved {
  from = kubectl_manifest.wf_on_demand_arm_node_pool
  to   = kubectl_manifest.wf_on_demand_arm_node_pool[0]
}

moved {
  from = random_id.on_demand_node_pool_name
  to   = random_id.on_demand_node_pool_name[0]
}

moved {
  from = kubectl_manifest.on_demand_node_pool
  to   = kubectl_manifest.on_demand_node_pool[0]
}

moved {
  from = kubectl_manifest.wf_on_demand_node_pool
  to   = kubectl_manifest.wf_on_demand_node_pool[0]
}

moved {
  from = module.node_settings_burstable
  to   = module.node_settings_burstable[0]
}

moved {
  from = module.node_settings_spot
  to   = module.node_settings_spot[0]
}

moved {
  from = module.node_settings
  to   = module.node_settings[0]
}

moved {
  from = data.aws_ami.arm64_ami
  to   = data.aws_ami.arm64_ami[0]
}

moved {
  from = data.aws_ami.amd64_ami
  to   = data.aws_ami.amd64_ami[0]
}
