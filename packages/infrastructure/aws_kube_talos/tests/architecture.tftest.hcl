mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}
mock_provider "talos" {}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { jwks_json = "{}", member_ips = "10.0.1.10,10.0.2.10" } }
  }
}
mock_provider "pf" {}

override_resource {
  target = aws_launch_template.worker
  values = { id = "lt-0000000000000000a" }
}

override_resource {
  target = aws_launch_template.worker_on_demand
  values = { id = "lt-0000000000000000b" }
}

override_resource {
  target = aws_eip.api
  values = { public_ip = "192.0.2.10" }
}

variables {
  cluster_name              = "test"
  vpc_id                    = "vpc-00000000"
  control_plane_private_ips = ["10.0.1.10"]
  # Placeholder PKI; the provider is mocked, so no value is parsed.
  machine_secrets = {
    certs = {
      etcd               = { cert = "x", key = "x" }
      k8s                = { cert = "x", key = "x" }
      k8s_aggregator     = { cert = "x", key = "x" }
      k8s_serviceaccount = { key = "x" }
      os                 = { cert = "x", key = "x" }
    }
    cluster    = { id = "x", secret = "x" }
    secrets    = { bootstrap_token = "x", secretbox_encryption_secret = "x" }
    trustdinfo = { token = "x" }
  }
  client_configuration = { ca_certificate = "x", client_certificate = "x", client_key = "x" }
}

run "arm64_defaults" {
  command = plan
}
run "reject_x86_worker" {
  command = plan
  variables { worker_instance_type = "m6i.large" }
  override_data {
    target = data.aws_ec2_instance_type.node
    values = { supported_architectures = ["x86_64"] }
  }
  expect_failures = [data.aws_ec2_instance_type.node]
}

run "arm64_fallbacks" {
  command = plan
  variables {
    control_plane_instance_types = ["t4g.medium", "m7g.large", "c7g.large"]
    worker_instance_types        = ["c7g.large", "c8g.large"]
  }
  assert {
    condition     = length(local.node_instance_types) == 4
    error_message = "Every controller override and worker fallback must be checked."
  }
}
run "reject_x86_controller" {
  command = plan
  variables { control_plane_instance_type = "m6i.large" }
  override_data {
    target = data.aws_ec2_instance_type.node
    values = { supported_architectures = ["x86_64"] }
  }
  expect_failures = [data.aws_ec2_instance_type.node]
}
run "reject_x86_fallback" {
  command = plan
  variables { worker_instance_types = ["c7g.large", "m6i.large"] }
  override_data {
    target = data.aws_ec2_instance_type.node
    values = { supported_architectures = ["x86_64"] }
  }
  expect_failures = [data.aws_ec2_instance_type.node]
}

run "fixed_controller_ip_and_user_data_sans" {
  command = plan
  variables { control_plane_private_ips = ["10.0.1.10"] }
  assert {
    condition     = aws_instance.control_plane[0].private_ip == "10.0.1.10"
    error_message = "control_plane_private_ips must set the controller's private IP."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "127.0.0.1")
    error_message = "Control plane user data must carry the 127.0.0.1 SANs for tunnel bootstrap."
  }
}

run "reject_private_ip_count_mismatch" {
  command = plan
  variables { control_plane_private_ips = ["10.0.1.10", "10.0.1.11"] }
  expect_failures = [aws_instance.control_plane]
}

run "reject_private_without_address" {
  command = plan
  variables { control_plane_private_ips = [] }
  expect_failures = [aws_instance.control_plane]
}

run "public_opt_in_keeps_elastic_ip" {
  command = plan
  variables {
    control_plane_public_ip_enabled = true
    control_plane_subnets           = ["PUBLIC_A", "PUBLIC_B", "PUBLIC_C"]
    talos_api_endpoint              = null
  }
  assert {
    condition     = length(aws_eip.api) == 1 && aws_instance.control_plane[0].associate_public_ip_address
    error_message = "Opting in must keep the Elastic IP and public address."
  }
}

run "three_unique_subnets_plan_three_controllers" {
  command = plan
  variables {
    control_plane_count       = 3
    control_plane_subnets     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name      = "api.test.internal"
  }
  assert {
    condition     = length(aws_instance.control_plane) == 3 && length(talos_machine_configuration_apply.control_plane) == 3
    error_message = "Three subnets must plan three controllers."
  }
  assert {
    condition     = aws_instance.control_plane[2].tags["Name"] == "test-control-plane-2"
    error_message = "Name tags must keep the position suffix."
  }
}

run "bootstrap_follows_named_subnet" {
  command = plan
  variables {
    control_plane_count       = 3
    control_plane_subnets     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name      = "api.test.internal"
    bootstrap_control_plane   = "PRIVATE_B"
  }
  assert {
    condition     = local.bootstrap_index == 1
    error_message = "bootstrap_control_plane must select its subnet's position."
  }
}

run "reject_inactive_bootstrap" {
  command = plan
  variables {
    control_plane_subnets   = ["PRIVATE_A", "PRIVATE_B"]
    bootstrap_control_plane = "PRIVATE_B"
  }
  expect_failures = [aws_instance.control_plane]
}

run "reject_duplicate_subnets" {
  command = plan
  variables { control_plane_subnets = ["PRIVATE_A", "PRIVATE_A"] }
  expect_failures = [var.control_plane_subnets]
}

run "operator_tunnel_rules_per_group_and_port" {
  command = plan
  variables {
    operator_tunnel_security_group_ids = ["sg-00000000000000001", "sg-00000000000000002"]
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.operator_tunnel) == 4
    error_message = "Expected a kubernetes and a talos rule for each tunnel security group."
  }
}

run "no_snapshot_without_existing_controllers" {
  command = plan
  variables {
    control_plane_count       = 3
    control_plane_subnets     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name      = "api.test.internal"
  }
  assert {
    condition     = length(terraform_data.pre_membership_snapshot) == 0
    error_message = "First bootstrap has no cluster to snapshot."
  }
}

run "no_snapshot_when_keys_unchanged" {
  command = plan
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"] }
  }
  assert {
    condition     = length(terraform_data.pre_membership_snapshot) == 0
    error_message = "Unchanged keys must not run a snapshot."
  }
}

run "snapshot_when_controllers_added" {
  command = plan
  variables {
    control_plane_count                     = 3
    control_plane_subnets                   = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips               = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name                    = "api.test.internal"
    etcd_pre_membership_snapshot_kubeconfig = "/tmp/kubeconfig"
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"] }
  }
  assert {
    condition     = length(terraform_data.pre_membership_snapshot) == 1
    error_message = "Adding controllers must snapshot first."
  }
}

run "reject_snapshot_without_kubeconfig" {
  command = plan
  variables {
    control_plane_count       = 3
    control_plane_subnets     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name      = "api.test.internal"
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"] }
  }
  expect_failures = [terraform_data.pre_membership_snapshot]
}

run "reject_snapshot_with_empty_kubeconfig" {
  command = plan
  variables {
    control_plane_count                     = 3
    control_plane_subnets                   = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips               = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name                    = "api.test.internal"
    etcd_pre_membership_snapshot_kubeconfig = " "
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"] }
  }
  expect_failures = [terraform_data.pre_membership_snapshot]
}

run "opt_out_skips_snapshot" {
  command = plan
  variables {
    control_plane_count                  = 3
    control_plane_subnets                = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips            = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name                 = "api.test.internal"
    etcd_pre_membership_snapshot_enabled = false
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"] }
  }
  assert {
    condition     = length(terraform_data.pre_membership_snapshot) == 0
    error_message = "Opt-out must skip the snapshot."
  }
}

run "cluster_region_output" {
  command = plan
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-2" }
  }
  assert {
    condition     = output.cluster_region == "us-east-2"
    error_message = "cluster_region must equal the deployed AWS region."
  }
}

run "controller_class_label_and_taint_by_default" {
  command = plan
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "panfactum.com/class\": \"controller")
    error_message = "Controllers must carry the Panfactum controller class label by default."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"controller\": \"true:NoSchedule\"")
    error_message = "Controllers must always carry controller=true:NoSchedule."
  }
}

run "workloads_disabled_has_no_label_or_taint" {
  command = plan
  variables { control_plane_workloads_enabled = false }
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "panfactum.com/class\": \"controller")
    error_message = "Without control plane workloads there must be no controller class label."
  }
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"controller\": \"true:NoSchedule\"")
    error_message = "Without control plane workloads there must be no controller taint."
  }
}

run "controller_taint_without_aws_node_config" {
  command = plan
  variables { aws_node_config_enabled = false }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"controller\": \"true:NoSchedule\"")
    error_message = "The controller taint must apply without aws_node_config_enabled too."
  }
}

run "controller_taint_with_aws_node_config" {
  command = plan
  variables { aws_node_config_enabled = true }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"controller\": \"true:NoSchedule\"")
    error_message = "The controller taint must apply with aws_node_config_enabled."
  }
}

# Adding controllers must not defer the worker config, or worker launch templates churn.
run "worker_config_known_while_adding_controllers" {
  command = plan
  variables {
    control_plane_count       = 3
    control_plane_subnets     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name      = "api.test.internal"
  }
  assert {
    condition     = output.worker_machine_configuration != null
    error_message = "Worker config must be known at plan time when private_api_dns_name is set."
  }
}

# etcd quorum: 3 members tolerate one loss and 5 tolerate two; even counts add no tolerance.
run "five_controllers_accepted" {
  command = plan
  variables {
    control_plane_count       = 5
    control_plane_subnets     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C", "PRIVATE_D", "PRIVATE_E"]
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10", "10.0.3.10", "10.0.4.10", "10.0.5.10"]
    private_api_dns_name      = "api.test.internal"
  }
  assert {
    condition     = length(aws_instance.control_plane) == 5
    error_message = "control_plane_count = 5 must plan five controllers."
  }
}

run "reject_two_controllers" {
  command = plan
  variables {
    control_plane_count       = 2
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10"]
    private_api_dns_name      = "api.test.internal"
  }
  expect_failures = [var.control_plane_count]
}

run "reject_four_controllers" {
  command = plan
  variables {
    control_plane_count       = 4
    control_plane_subnets     = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C", "PRIVATE_D"]
    control_plane_private_ips = ["10.0.1.10", "10.0.2.10", "10.0.3.10", "10.0.4.10"]
    private_api_dns_name      = "api.test.internal"
  }
  expect_failures = [var.control_plane_count]
}

run "private_api_is_a_records_to_controller_ips" {
  command = plan
  variables {
    control_plane_count       = 3
    control_plane_subnets     = ["PRIVATE_B", "PRIVATE_A", "PRIVATE_C"]
    control_plane_private_ips = ["10.0.2.10", "10.0.1.10", "10.0.3.10"]
    private_api_dns_name      = "api.test.internal"
  }
  assert {
    condition     = length(aws_route53_record.private_api[0].alias) == 0 && aws_route53_record.private_api[0].ttl == 30 && aws_route53_record.private_api[0].type == "A"
    error_message = "The private API name must be an A record with TTL 30, not an alias."
  }
  assert {
    condition     = toset(aws_route53_record.private_api[0].records) == toset(["10.0.2.10", "10.0.1.10", "10.0.3.10"])
    error_message = "The private API A record must list every controller IP."
  }
}

run "controllers_are_on_demand_with_instance_profile" {
  command = plan
  variables {
    control_plane_count         = 3
    control_plane_subnets       = ["PRIVATE_A", "PRIVATE_B", "PRIVATE_C"]
    control_plane_private_ips   = ["10.0.1.10", "10.0.2.10", "10.0.3.10"]
    private_api_dns_name        = "api.test.internal"
    controller_instance_profile = "test-ctrl"
  }
  assert {
    condition     = alltrue([for i in aws_instance.control_plane : length(i.instance_market_options) == 0 && i.iam_instance_profile == "test-ctrl"])
    error_message = "Every controller must be on-demand and carry the controller instance profile."
  }
}

# Resizing one controller must be an in-place stop/start. Mocks cannot see the AWS provider's own
# replace decisions (a live plan covers those), so this pins every module-side trigger.
run "resize_one_controller_changes_only_its_type" {
  command = plan
  variables {
    control_plane_count          = 3
    control_plane_subnets        = ["PRIVATE_B", "PRIVATE_A", "PRIVATE_C"]
    control_plane_private_ips    = ["10.0.2.10", "10.0.1.10", "10.0.3.10"]
    private_api_dns_name         = "api.test.internal"
    control_plane_instance_types = ["t4g.large", "t4g.large", "t4g.large"]
  }
  assert {
    condition     = [for i in aws_instance.control_plane : i.instance_type] == ["t4g.large", "t4g.large", "t4g.large"]
    error_message = "Each controller must take its own control_plane_instance_types entry."
  }
  assert {
    condition     = [for i in aws_instance.control_plane : i.private_ip] == ["10.0.2.10", "10.0.1.10", "10.0.3.10"]
    error_message = "A resize must keep each controller's fixed IP."
  }
  assert {
    condition     = alltrue([for i in aws_instance.control_plane : i.user_data_replace_on_change != true && length(i.launch_template) == 0 && length(i.instance_market_options) == 0])
    error_message = "Controllers must not replace on user data changes or follow a launch template or Spot request."
  }
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "t4g.")
    error_message = "Controller user data must not depend on the instance type."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "KubeServiceAccountConfig")
    error_message = "Controller user data must carry the OIDC issuer so a replaced controller never serves the default issuer."
  }
}

# Karpenter launches every worker; the ASG path must allow zero and keep the outputs Karpenter reads.
run "zero_workers_create_no_asgs" {
  command = plan
  variables {
    aws_node_config_enabled  = true
    worker_count             = 0
    on_demand_worker_subnets = []
    private_api_dns_name     = "api.test.internal"
  }
  assert {
    condition     = length(aws_launch_template.worker) + length(aws_autoscaling_group.worker) + length(aws_launch_template.worker_on_demand) + length(aws_autoscaling_group.worker_on_demand) == 0
    error_message = "worker_count = 0 with no on-demand subnets must create no worker launch templates or ASGs."
  }
  assert {
    condition     = output.worker_machine_configuration != null
    error_message = "Karpenter still needs worker_machine_configuration."
  }
  assert {
    condition     = output.talos_ami_id != null
    error_message = "Karpenter still needs talos_ami_id."
  }
}

run "default_workers_keep_spot_asg" {
  command = plan
  assert {
    condition     = length(aws_autoscaling_group.worker) == 1 && length(aws_launch_template.worker) == 1
    error_message = "worker_count above 0 must keep the Spot worker ASG."
  }
}

# override_data skips postconditions, so the mock external provider supplies members 10.0.1.10 and 10.0.2.10.
run "shrink_blocked_while_removed_controller_is_etcd_member" {
  command = plan
  variables {
    control_plane_count       = 1
    control_plane_subnets     = ["a", "b", "c"]
    control_plane_private_ips = ["10.0.1.10"]
    talos_api_endpoint        = "127.0.0.1"
  }
  override_data {
    target = data.aws_instances.removed_control_plane
    values = { ids = ["i-0000000000000002"], private_ips = ["10.0.2.10"] }
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000001"], private_ips = ["10.0.1.10"] }
  }
  expect_failures = [data.external.etcd_members]
}

run "shrink_allowed_after_etcd_leave" {
  command = plan
  variables {
    control_plane_count       = 1
    control_plane_subnets     = ["a", "b", "c"]
    control_plane_private_ips = ["10.0.1.10"]
    talos_api_endpoint        = "127.0.0.1"
  }
  override_data {
    target = data.aws_instances.removed_control_plane
    values = { ids = ["i-0000000000000002"], private_ips = ["10.0.3.10"] }
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000001"], private_ips = ["10.0.1.10"] }
  }
}

run "no_removed_controllers_makes_no_external_call" {
  command = plan
  assert {
    condition     = length(data.external.etcd_members) == 0
    error_message = "The etcd member lookup must only run when a removed controller exists."
  }
}
