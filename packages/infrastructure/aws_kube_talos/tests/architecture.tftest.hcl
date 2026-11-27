mock_provider "aws" {
  mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws", dns_suffix = "amazonaws.com" } }
  mock_data "aws_region" { defaults = { region = "us-east-2", name = "us-east-2" } }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/test-api/0123456789abcdef" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/test-api/0123456789abcdef" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { bucket_regional_domain_name = "test-oidc.s3.us-east-2.amazonaws.com" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/test-oidc.s3.us-east-2.amazonaws.com" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
  mock_data "aws_security_groups" {
    defaults = { ids = [] }
  }
}
# NOTE: Plan native Talos resources with the real provider because OpenTofu 1.8 mocks cannot synthesize their optional nested attributes.
override_data {
  target = data.talos_machine_configuration.control_plane
  values = { machine_configuration = "machine: {}" }
}
override_data {
  target = data.talos_machine_configuration.control_plane_runtime
  values = { machine_configuration = "machine: {}" }
}
override_data {
  target = data.talos_client_configuration.this
  values = { talos_config = "fixture" }
}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { jwks_json = "{}", member_ips = "10.0.1.10,10.0.2.10" } }
  }
}
mock_provider "pf" {}

override_resource {
  target = aws_eip.api
  values = { public_ip = "192.0.2.10" }
}

variables {
  cluster_name  = "test"
  vpc_id        = "vpc-00000000"
  control_plane = [{ subnet = "PRIVATE_A", private_ip = "10.0.1.10" }]
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

run "lifecycle_lock_default" {
  command = plan

  assert {
    condition     = var.lifecycle_lock && !aws_s3_bucket.etcd_backup.force_destroy && !aws_s3_bucket.service_account_oidc[0].force_destroy
    error_message = "The lifecycle lock must be enabled and both buckets must retain their contents by default."
  }
}

run "lifecycle_lock_disabled" {
  command = plan

  variables {
    lifecycle_lock = false
  }

  assert {
    condition     = aws_s3_bucket.etcd_backup.force_destroy && aws_s3_bucket.service_account_oidc[0].force_destroy
    error_message = "Disabling the lifecycle lock must allow both versioned buckets to be emptied during deletion."
  }
}

run "external_cloud_provider" {
  command = plan
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"cloud-provider\": \"external\"")
    error_message = "Controllers must use the external AWS cloud provider by default."
  }
}

run "scheduler_default_disabled" {
  command = plan

  assert {
    condition     = alltrue([for patch in local.control_plane_base_patches : try(yamldecode(patch).kind, "") != "KubeSchedulerConfig"])
    error_message = "The Panfactum scheduler must be opt-in."
  }
}

run "scheduler_enabled_with_caller_patch" {
  command = plan
  variables {
    panfactum_scheduler_enabled  = true
    kube_version                 = "1.35.10"
    control_plane_config_patches = ["{\"machine\":{\"network\":{\"hostname\":\"custom-node\"}}}"]
  }

  assert {
    condition = yamldecode(reverse(local.control_plane_base_patches)[1]) == {
      apiVersion = "v1alpha1"
      kind       = "KubeSchedulerConfig"
      image      = "registry.k8s.io/kube-scheduler:v1.35.10"
      config = {
        profiles = [
          { schedulerName = "default-scheduler" },
          {
            schedulerName = "panfactum"
            plugins       = { score = { enabled = [{ name = "NodeResourcesFit", weight = 2 }] } }
            pluginConfig = [{
              name = "NodeResourcesFit"
              args = { scoringStrategy = { type = "MostAllocated", resources = [{ name = "cpu", weight = 1 }, { name = "memory", weight = 1 }] } }
            }]
          },
        ]
      }
    }
    error_message = "The scheduler patch must retain both profiles and the versioned image."
  }
  assert {
    condition     = reverse(local.control_plane_base_patches)[0] == var.control_plane_config_patches[0]
    error_message = "Caller patches must follow the scheduler patch."
  }
}

run "arm64_fallbacks" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10", instance_type = "m7g.large" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10", instance_type = "c7g.large" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  assert {
    condition     = local.node_instance_types == toset(["t4g.medium", "m7g.large", "c7g.large"])
    error_message = "Every controller override must be checked."
  }
}
run "reject_x86_controller" {
  command = plan
  variables { control_plane = [{ subnet = "PRIVATE_A", private_ip = "10.0.1.10", instance_type = "m6i.large" }] }
  override_data {
    target = data.aws_ec2_instance_type.node
    values = { supported_architectures = ["x86_64"] }
  }
  expect_failures = [data.aws_ec2_instance_type.node]
}
run "fixed_controller_ip_and_requested_user_data_sans" {
  command = plan
  variables {
    control_plane        = [{ subnet = "PRIVATE_A", private_ip = "10.0.1.10" }]
    kube_api_extra_sans  = ["127.0.0.1"]
    talos_api_extra_sans = ["127.0.0.1"]
  }
  assert {
    condition     = aws_instance.control_plane[0].private_ip == "10.0.1.10"
    error_message = "control_plane_private_ips must set the controller's private IP."
  }
  assert {
    condition     = contains(yamldecode(local.api_san_patch).certExtraSANs, "127.0.0.1") && local.talos_api_sans == tolist(["127.0.0.1"])
    error_message = "Control plane user data must carry the requested loopback SANs for both APIs."
  }
}

run "reject_private_without_address" {
  command = plan
  variables { control_plane = [{ subnet = "PRIVATE_A" }] }
  expect_failures = [aws_instance.control_plane]
}

run "public_opt_in_keeps_elastic_ip" {
  command = plan
  variables {
    control_plane_public_ip_enabled = true
    control_plane                   = [{ subnet = "PUBLIC_A", private_ip = "10.0.1.10" }]
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
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  assert {
    condition     = length(aws_instance.control_plane) == 3 && length(talos_machine.control_plane) == 3
    error_message = "Three subnets must plan three controllers."
  }
  assert {
    condition     = toset(talos_cluster.this.control_plane_nodes) == toset(var.control_plane[*].private_ip)
    error_message = "Native cluster health checks must include every controller IP."
  }
  assert {
    condition     = aws_instance.control_plane[2].tags["Name"] == "test-control-plane-2"
    error_message = "Name tags must keep the position suffix."
  }
}

run "bootstrap_follows_first_entry" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name   = "api.test.internal"
    talos_access_transport = "vpn"
  }
  assert {
    condition     = talos_machine.control_plane[0].endpoint == "10.0.2.10"
    error_message = "Routed access must use the first control_plane entry."
  }
}

run "reject_duplicate_subnets" {
  command = plan
  variables { control_plane = [{ subnet = "PRIVATE_A" }, { subnet = "PRIVATE_A" }, { subnet = "PRIVATE_B" }] }
  expect_failures = [var.control_plane]
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
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name = "api.test.internal"
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
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
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
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name = "api.test.internal"
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
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
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
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
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

run "controller_taint_with_aws_node_configuration" {
  command = plan
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"controller\": \"true:NoSchedule\"")
    error_message = "The controller taint must apply with AWS node configuration."
  }
}

# Adding controllers must not defer the worker config, or worker launch templates churn.
run "node_bootstrap_known_while_adding_controllers" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  assert {
    condition     = output.node_bootstrap.cluster_endpoint != null
    error_message = "Worker config must be known at plan time when private_api_dns_name is set."
  }
}

# etcd quorum: 3 members tolerate one loss and 5 tolerate two; even counts add no tolerance.
run "five_controllers_accepted" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
      { subnet = "PRIVATE_D", private_ip = "10.0.4.10" },
      { subnet = "PRIVATE_E", private_ip = "10.0.5.10" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  assert {
    condition     = length(aws_instance.control_plane) == 5
    error_message = "Five control_plane entries must plan five controllers."
  }
}

run "reject_two_controllers" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  expect_failures = [var.control_plane]
}

run "reject_four_controllers" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
      { subnet = "PRIVATE_D", private_ip = "10.0.4.10" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  expect_failures = [var.control_plane]
}

run "private_api_is_a_records_to_controller_ips" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name      = "api.test.internal"
    api_load_balancer_enabled = false
  }
  assert {
    condition     = length(aws_route53_record.private_api[0].alias) == 0 && aws_route53_record.private_api[0].ttl == 30 && aws_route53_record.private_api[0].type == "A"
    error_message = "The private API name must be an A record with TTL 30, not an alias."
  }
  assert {
    condition     = toset(aws_route53_record.private_api[0].records) == toset(["10.0.2.10", "10.0.1.10", "10.0.3.10"])
    error_message = "The private API A record must list every controller IP."
  }
  assert {
    condition     = data.talos_machine_configuration.control_plane.cluster_endpoint == "https://api.test.internal:6443" && output.node_bootstrap.cluster_endpoint == "https://api.test.internal:6443"
    error_message = "Controllers and workers must share the private API hostname."
  }
  assert {
    condition     = contains(yamldecode(local.api_san_patch).certExtraSANs, "api.test.internal")
    error_message = "The Kubernetes API certificate must include the private API hostname."
  }
}

run "controllers_are_on_demand_with_instance_profile" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name        = "api.test.internal"
    controller_instance_profile = "test-ctrl"
  }
  assert {
    condition     = alltrue([for i in aws_instance.control_plane : length(i.instance_market_options) == 0 && i.iam_instance_profile == "test-ctrl"])
    error_message = "Every controller must be on-demand and carry the controller instance profile."
  }
}

# Resizing one controller must be an in-place stop/start. Mocks cannot see the AWS provider's own
# replace decisions (the talos-2 plan demo covers those), so this pins every module-side trigger.
run "resize_one_controller_changes_only_its_type" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10", instance_type = "t4g.large" },
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10", instance_type = "t4g.large" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10", instance_type = "t4g.large" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  assert {
    condition     = [for i in aws_instance.control_plane : i.instance_type] == ["t4g.large", "t4g.large", "t4g.large"]
    error_message = "Each controller must take its own control_plane instance_type."
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

run "karpenter_worker_configuration_outputs" {
  command = plan
  variables {
    private_api_dns_name = "api.test.internal"
  }
  assert {
    condition     = output.node_bootstrap.cluster_endpoint != null
    error_message = "Karpenter still needs the private cluster endpoint."
  }
  assert {
    condition     = output.talos_ami_id != null
    error_message = "Karpenter still needs talos_ami_id."
  }
  assert {
    condition     = startswith(output.node_bootstrap.installer_image, "factory.talos.dev/aws-installer/") && endswith(output.node_bootstrap.installer_image, ":${var.talos_version}")
    error_message = "Karpenter needs the version-matched AWS installer even when no installer_image is supplied."
  }
}

run "bootstrap_mode_drops_taints" {
  command = plan
  variables {
    bootstrap_mode_enabled = true
  }
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"controller\": \"true:NoSchedule\"")
    error_message = "Bootstrap mode must not add the controller taint."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"node-role.kubernetes.io/control-plane\":\n    \"$patch\": \"delete\"")
    error_message = "Bootstrap mode must delete the control-plane taint."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "panfactum.com/class\": \"controller")
    error_message = "Bootstrap mode must keep the controller class label."
  }
}

run "bootstrap_mode_deletes_control_plane_taint_without_workloads" {
  command = plan
  variables {
    bootstrap_mode_enabled          = true
    control_plane_workloads_enabled = false
  }
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"controller\": \"true:NoSchedule\"")
    error_message = "Bootstrap mode must not add the controller taint."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"node-role.kubernetes.io/control-plane\":\n    \"$patch\": \"delete\"")
    error_message = "Bootstrap mode must delete the control-plane taint even without control plane workloads."
  }
}

run "networking_disabled_without_inputs" {
  command = plan
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"$patch\": \"delete\"\n\"apiVersion\": \"v1alpha1\"\n\"kind\": \"KubeFlannelCNIConfig\"")
    error_message = "Controllers must delete Flannel."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"enabled\": false\n\"kind\": \"KubeProxyConfig\"")
    error_message = "Controllers must disable kube-proxy."
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"enabled\": false\n\"kind\": \"KubeCoreDNSConfig\"")
    error_message = "Controllers must disable CoreDNS."
  }
}

# override_data skips postconditions, so the mock external provider supplies members 10.0.1.10 and 10.0.2.10.
run "shrink_blocked_while_removed_controller_is_etcd_member" {
  command = plan
  variables {
    control_plane      = [{ subnet = "a", private_ip = "10.0.1.10" }]
    talos_api_endpoint = "127.0.0.1"
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
    control_plane      = [{ subnet = "a", private_ip = "10.0.1.10" }]
    talos_api_endpoint = "127.0.0.1"
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

run "direct_private_api_has_no_ssm_dependency" {
  command = plan
  variables {
    private_api_dns_name             = "api.test.internal"
    talos_api_endpoint               = "10.0.9.10"
    talos_access_transport           = "vpn"
    kube_api_source_security_groups  = { runner = "sg-00000000000000001" }
    talos_api_source_security_groups = { runner = "sg-00000000000000001" }
  }
  assert {
    condition     = local.ssm_jump_host_count == 0 && length(aws_vpc_security_group_ingress_rule.operator_tunnel) == 0
    error_message = "A direct cluster must not own a jump host or legacy tunnel ingress."
  }
  assert {
    condition     = output.ssm_jump_host_instance_id == null && output.ssm_jump_host_security_group_id == null
    error_message = "Jump host outputs must be null when disabled."
  }
  assert {
    condition     = local.talos_api_endpoint == "10.0.9.10" && output.cluster_url == "https://api.test.internal:6443"
    error_message = "An explicit Talos endpoint must win over automatic VPN routing."
  }
  assert {
    condition     = length(local.talos_api_patches) == 0 && !contains(yamldecode(local.api_san_patch).certExtraSANs, "127.0.0.1")
    error_message = "Direct reachability must not require loopback SANs."
  }
  assert {
    condition     = aws_instance.control_plane[0].tags["kubernetes.io/cluster/test"] == "owned"
    error_message = "Controllers must receive the cluster ownership tag."
  }
}

run "caller_owned_ssm_path" {
  command = plan
  variables {
    private_api_dns_name             = "api.test.internal"
    talos_api_endpoint               = "127.0.0.1:50003"
    kube_api_extra_sans              = ["127.0.0.1", "kubectl.test.internal"]
    talos_api_extra_sans             = ["127.0.0.1"]
    kube_api_source_security_groups  = { jump = "sg-00000000000000001", kubectl_runner = "sg-00000000000000002" }
    talos_api_source_security_groups = { jump = "sg-00000000000000001", recovery = "sg-00000000000000003" }
  }
  assert {
    condition     = local.ssm_jump_host_count == 0 && length(aws_vpc_security_group_ingress_rule.operator_tunnel) == 0
    error_message = "A caller-owned SSM path must not create a cluster-owned jump host or legacy tunnel ingress."
  }
  assert {
    condition     = local.talos_api_endpoint == "127.0.0.1:50003" && toset(yamldecode(local.api_san_patch).certExtraSANs) == toset(["10.0.1.10", "api.test.internal", "127.0.0.1", "kubectl.test.internal"]) && local.talos_api_sans == tolist(["127.0.0.1"])
    error_message = "The cluster must retain private DNS and use the caller's Talos endpoint and SANs."
  }
  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.kube_api_source)) == toset(["jump", "kubectl_runner"]) && toset(keys(aws_vpc_security_group_ingress_rule.talos_api_source)) == toset(["jump", "recovery"])
    error_message = "The Kubernetes-only and Talos-only sources must stay independent."
  }
  assert {
    condition     = alltrue([for key, rule in aws_vpc_security_group_ingress_rule.kube_api_source : rule.referenced_security_group_id == var.kube_api_source_security_groups[key] && rule.ip_protocol == "tcp" && rule.from_port == 6443 && rule.to_port == 6443])
    error_message = "Each caller-owned Kubernetes source must receive only TCP 6443."
  }
  assert {
    condition     = alltrue([for key, rule in aws_vpc_security_group_ingress_rule.talos_api_source : rule.referenced_security_group_id == var.talos_api_source_security_groups[key] && rule.ip_protocol == "tcp" && rule.from_port == 50000 && rule.to_port == 50000])
    error_message = "Each caller-owned Talos source must receive only TCP 50000."
  }
}

run "fixed_ssm_first_bootstrap" {
  command = plan
  variables {
    private_api_dns_name             = "api.test.internal"
    talos_access_transport           = "ssm"
    kube_api_source_security_groups  = { jump = "sg-00000000000000001" }
    talos_api_source_security_groups = { jump = "sg-00000000000000001" }
    service_subnets                  = ["10.113.0.0/16"]
    kube_version                     = "1.36.5"
  }
  assert {
    condition     = talos_cluster.this.endpoint == "127.0.0.1" && length(aws_instance.ssm_jump_host) == 0
    error_message = "First bootstrap must use the module hook's loopback forward and the standalone SSM host."
  }
  assert {
    condition     = contains(yamldecode(local.api_san_patch).certExtraSANs, "127.0.0.1") && contains(local.talos_api_sans, "127.0.0.1")
    error_message = "Fixed SSM must verify both APIs through loopback."
  }
  assert {
    condition     = output.dns_service_ip == "10.113.0.10" && output.kubernetes_version == "1.36.5"
    error_message = "CoreDNS must receive the Talos service DNS IP and Kubernetes version."
  }
  assert {
    condition     = aws_instance.control_plane[0].tags["kubernetes.io/cluster/test"] == "owned"
    error_message = "The cloud provider must discover controllers by their cluster tag."
  }
}

run "ssm_jump_host_enabled" {
  command = plan
  variables {
    ssm_jump_host_enabled = true
    private_api_dns_name  = "api.test.internal"
  }
  assert {
    condition     = aws_instance.control_plane[0].associate_public_ip_address == false && length(aws_eip.api) == 0
    error_message = "A private cluster must launch its controller without a public IP or EIP."
  }
  assert {
    condition     = aws_security_group.ssm_jump_host[0].vpc_id == var.vpc_id && aws_security_group.nodes.vpc_id == var.vpc_id && length(aws_vpc_security_group_ingress_rule.operator_tunnel) == 0
    error_message = "The cluster and jump host must use the shared VPC without an external tunnel security group."
  }
  assert {
    condition     = local.cluster_endpoint == "https://api.test.internal:6443" && local.talos_api_endpoint == "127.0.0.1"
    error_message = "The Kubernetes API must use private DNS and the Talos provider must use the local tunnel."
  }
  assert {
    condition     = contains(yamldecode(local.api_san_patch).certExtraSANs, "127.0.0.1") && local.talos_api_sans == tolist(["127.0.0.1"])
    error_message = "Existing jump hosts must retain the loopback SAN on both APIs."
  }
  assert {
    condition     = length(aws_instance.ssm_jump_host) == 1 && aws_instance.ssm_jump_host[0].associate_public_ip_address == false
    error_message = "Enabling must plan one jump host without a public IP."
  }
  assert {
    condition     = aws_instance.ssm_jump_host[0].metadata_options[0].http_tokens == "required" && aws_instance.ssm_jump_host[0].root_block_device[0].encrypted == true
    error_message = "The jump host must require IMDSv2 and encrypt its root volume."
  }
  assert {
    condition     = aws_instance.ssm_jump_host[0].tags["Name"] == "test-ssm-tunnel"
    error_message = "cluster_access.py discovers the host by the name <cluster_name>-ssm-tunnel."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.ssm_jump_host_kubernetes[0].from_port == 6443 && aws_vpc_security_group_ingress_rule.ssm_jump_host_talos[0].from_port == 50000
    error_message = "The node security group must admit the jump host on 6443 and 50000."
  }
  assert {
    condition     = length(aws_security_group.ssm_jump_host[0].ingress) == 0
    error_message = "The jump host security group must have no ingress."
  }
}

run "reject_x86_ssm_jump_host" {
  command = plan
  variables {
    ssm_jump_host_enabled       = true
    ssm_jump_host_instance_type = "t3.nano"
  }
  override_data {
    target = data.aws_ec2_instance_type.node
    values = { supported_architectures = ["x86_64"] }
  }
  expect_failures = [data.aws_ec2_instance_type.node]
}

run "api_lb_disabled_keeps_controller_ip_record" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name      = "api.test.internal"
    api_load_balancer_enabled = false
  }
  assert {
    condition     = length(aws_lb.api) == 0 && length(aws_lb_target_group.api) == 0 && length(aws_lb_listener.api) == 0 && length(aws_lb_target_group_attachment.api) == 0
    error_message = "Opting out must create no load balancer."
  }
  assert {
    condition     = length(aws_route53_record.private_api[0].alias) == 0 && length(aws_route53_record.private_api[0].records) == 3
    error_message = "Without the load balancer the record must list the controller IPs."
  }
}

run "api_lb_enabled_aliases_record" {
  command = plan
  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  assert {
    condition     = aws_lb.api[0].internal && aws_lb.api[0].load_balancer_type == "network" && aws_lb.api[0].enable_cross_zone_load_balancing
    error_message = "The load balancer must be an internal cross-zone NLB."
  }
  assert {
    condition     = aws_lb_target_group.api[0].health_check[0].protocol == "HTTPS" && aws_lb_target_group.api[0].health_check[0].path == "/readyz" && aws_lb_target_group.api[0].port == 6443 && aws_lb_target_group.api[0].health_check[0].interval == 5
    error_message = "The health check must be HTTPS /readyz on 6443 every 5 seconds."
  }
  assert {
    condition     = aws_lb_target_group.api[0].preserve_client_ip == "false" && length(aws_lb_target_group_attachment.api) == 3
    error_message = "Client IP preservation must be off and every controller attached."
  }
  assert {
    condition     = length(aws_route53_record.private_api[0].alias) == 1 && aws_route53_record.private_api[0].records == null
    error_message = "The record must be an alias to the load balancer."
  }
}

run "api_lb_skipped_without_private_dns" {
  command = plan
  assert {
    condition     = length(aws_lb.api) == 0 && length(aws_route53_record.private_api) == 0
    error_message = "Without private_api_dns_name the default must create no load balancer."
  }
}

run "controller_short_hostname_by_default" {
  command = plan
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "registerWithFQDN")
    error_message = "Controllers must keep the short hostname unless control_plane_register_with_fqdn is set."
  }
}

# Must be in the data source patches (user data), not only the later apply, so the first registration uses the FQDN.
run "controller_registers_with_fqdn_in_user_data" {
  command = plan
  variables {
    control_plane_register_with_fqdn = true
  }
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane.config_patches), "\"registerWithFQDN\": true")
    error_message = "control_plane_register_with_fqdn must put registerWithFQDN in the controller machine config."
  }
}

run "controller_provider_ids_output" {
  command = plan

  variables {
    control_plane = [
      { subnet = "PRIVATE_A", private_ip = "10.0.1.10" },
      { subnet = "PRIVATE_B", private_ip = "10.0.2.10" },
      { subnet = "PRIVATE_C", private_ip = "10.0.3.10" },
    ]
    private_api_dns_name = "api.test.internal"
  }
  override_resource {
    target = aws_instance.control_plane
    values = { id = "i-00000000000000001", availability_zone = "us-east-2a" }
  }

  assert {
    condition = output.controller_provider_ids == {
      "10.0.1.10" = "aws:///us-east-2a/i-00000000000000001"
      "10.0.2.10" = "aws:///us-east-2a/i-00000000000000001"
      "10.0.3.10" = "aws:///us-east-2a/i-00000000000000001"
    }
    error_message = "Each controller must be keyed by its private IP with an aws:///<az>/<instance-id> provider ID."
  }
}

run "no_serial_os_upgrade_on_new_cluster" {
  command = plan
  assert {
    condition     = length(terraform_data.talos_upgrade) == 0
    error_message = "A new cluster has no running controllers to upgrade."
  }
}

run "version_upgrades_follow_version_inputs" {
  command = plan
  variables {
    talos_version   = "v1.15.0"
    kube_version    = "1.38.0"
    installer_image = "factory.talos.dev/aws-installer/abc:v1.15.0"
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"], private_ips = ["10.0.1.10"] }
  }
  assert {
    condition     = terraform_data.talos_upgrade[0].triggers_replace[0] == "v1.15.0" && length(terraform_data.talos_upgrade[0].triggers_replace) == 1 && talos_cluster.this.kubernetes_version == "1.38.0"
    error_message = "Talos and Kubernetes upgrades must retain separate version inputs."
  }
  assert {
    condition     = talos_machine.control_plane[0].image == "factory.talos.dev/aws-installer/abc:v1.15.0" && talos_machine.control_plane[0].ignore_kubernetes_upgrade_drift
    error_message = "Machines must use the caller's installer on creation and leave Kubernetes image upgrades to the cluster resource."
  }
  assert {
    condition     = slice(data.talos_machine_configuration.control_plane_runtime.config_patches, 0, length(data.talos_machine_configuration.control_plane.config_patches) + length(local.backup_config_patches)) == tolist(concat(data.talos_machine_configuration.control_plane.config_patches, local.backup_config_patches))
    error_message = "The running controller config must retain the user-data patches and add the backup patches."
  }
}

run "version_upgrades_default_installer" {
  command = plan
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"], private_ips = ["10.0.1.10"] }
  }
  assert {
    condition     = local.upgrade_installer_image == "factory.talos.dev/aws-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.6"
    error_message = "Without installer_image the upgrade must use the official AWS installer for talos_version."
  }
  assert {
    condition     = contains([for patch in data.talos_machine_configuration.control_plane_runtime.config_patches : try(yamldecode(patch).kind, null)], "KubeCredentialProviderConfig") && !contains([for patch in data.talos_machine_configuration.control_plane.config_patches : try(yamldecode(patch).kind, null)], "KubeCredentialProviderConfig")
    error_message = "The ECR credential config must apply at runtime and stay out of boot user data, because stock AMIs lack the binary."
  }
}


run "image_factory_bootstrap" {
  command = plan
  variables {
    image_factory_schematic_id = "7835171368ed53d6f9ed4d298a4db7d4bcc745bbbca3f7cb2374967d64a6a8aa"
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"], private_ips = ["10.0.1.10"] }
  }
  assert {
    condition     = output.node_bootstrap.installer_image == "factory.talos.dev/aws-installer/${var.image_factory_schematic_id}:${var.talos_version}" && talos_machine.control_plane[0].image == output.node_bootstrap.installer_image
    error_message = "The controller and worker bootstrap must both use the supplied Image Factory schematic."
  }
  assert {
    condition     = one([for patch in local.aws_control_plane_patches : yamldecode(patch).installer.image if yamldecode(patch).kind == "UnattendedInstallConfig"]) == output.node_bootstrap.installer_image
    error_message = "The unattended install patch must use the resolved Factory installer."
  }
  assert {
    condition     = terraform_data.talos_upgrade[0].triggers_replace[0] == output.node_bootstrap.installer_image
    error_message = "Changing only the opt-in schematic must schedule a serial upgrade."
  }
}

run "reject_invalid_image_factory_schematic_id" {
  command = plan
  variables { image_factory_schematic_id = "not-a-schematic" }
  expect_failures = [var.image_factory_schematic_id]
}

run "reject_schematic_with_explicit_image" {
  command = plan
  variables {
    image_factory_schematic_id = "7835171368ed53d6f9ed4d298a4db7d4bcc745bbbca3f7cb2374967d64a6a8aa"
    installer_image            = "factory.talos.dev/aws-installer/explicit:v1.14.6"
  }
  expect_failures = [var.image_factory_schematic_id]
}

run "version_upgrades_opt_out" {
  command = plan
  variables { version_upgrades_enabled = false }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-0000000000000000a"], private_ips = ["10.0.1.10"] }
  }
  assert {
    condition     = length(terraform_data.talos_upgrade) == 0 && talos_cluster.this.kubernetes_version == var.kube_version
    error_message = "Disabling the serial Talos OS upgrade must leave Kubernetes under provider management."
  }
}

run "reject_installer_image_for_other_release" {
  command = plan
  variables {
    talos_version   = "v1.15.0"
    installer_image = "factory.talos.dev/aws-installer/abc:v1.14.6"
  }
  expect_failures = [talos_machine.control_plane]
}

run "controller_identity_configured" {
  command = plan
  variables {
    controller_identity = {
      name_prefix                            = "custom"
      ecr_cache_prefixes                     = ["github", "docker-hub", "quay", "kubernetes", "ecr-public"]
      controller_instance_profile_enabled    = true
      controller_additional_ecr_repositories = ["homelab-migrations/openbao"]
    }
  }
  override_resource {
    target = aws_iam_instance_profile.controller
    values = { name = "managed-controller" }
  }
  assert {
    condition     = aws_iam_role.controller[0].name_prefix == "custom-ctrl-" && aws_iam_instance_profile.controller[0].name_prefix == "custom-ctrl-" && aws_iam_role.controller[0].tags["Name"] == "custom-talos-worker"
    error_message = "Keep the established controller identity prefix and tags."
  }
  assert {
    condition     = aws_instance.control_plane[0].iam_instance_profile == "managed-controller" && length(aws_iam_role_policy.controller_read) == 1 && length(aws_iam_role_policy.controller_import) == 1
    error_message = "The enabled controller profile and import policies must be attached."
  }
  assert {
    condition     = one(data.aws_iam_policy_document.cache_import[0].statement).resources == toset([for prefix in ["github", "docker-hub", "quay", "kubernetes", "ecr-public"] : "arn:aws:ecr:us-east-2:123456789012:repository/${prefix}/*"]) && one(data.aws_iam_policy_document.cache_import[0].statement).actions == toset(["ecr:CreateRepository", "ecr:BatchImportUpstreamImage"])
    error_message = "Import access must be scoped to the specified cache prefixes."
  }
  assert {
    condition     = one([for s in data.aws_iam_policy_document.controller_read.statement : s if s.sid == "AdditionalExactRepositoryReads"]).resources == toset(["arn:aws:ecr:us-east-2:123456789012:repository/homelab-migrations/openbao"]) && one([for s in data.aws_iam_policy_document.controller_read.statement : s if s.sid == "AdditionalExactRepositoryReads"]).actions == toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"])
    error_message = "Additional controller access must grant only exact repository reads."
  }
}

run "controller_identity_external_profile_precedence" {
  command = plan
  variables {
    controller_identity         = { controller_instance_profile_enabled = true }
    controller_instance_profile = "external-controller"
  }
  assert {
    condition     = aws_instance.control_plane[0].iam_instance_profile == "external-controller" && length(aws_iam_instance_profile.controller) == 1
    error_message = "An explicit controller profile must take precedence over the managed profile."
  }
}

run "controller_identity_invalid_prefix" {
  command = plan
  variables { controller_identity = { name_prefix = "not valid!" } }
  expect_failures = [var.controller_identity]
}

run "controller_identity_invalid_cache" {
  command = plan
  variables { controller_identity = { ecr_cache_prefixes = ["other"] } }
  expect_failures = [var.controller_identity]
}

run "controller_identity_invalid_repository" {
  command = plan
  variables { controller_identity = { controller_additional_ecr_repositories = ["repo/*"] } }
  expect_failures = [var.controller_identity]
}

run "controller_identity_null_settings" {
  command = plan
  variables { controller_identity = null }
  assert {
    condition     = length(aws_iam_instance_profile.controller) == 0
    error_message = "Null identity settings must select the defaults."
  }
}

run "bootstrap_public_first_plan" {
  command = plan
  variables {
    talos_access_transport = "bootstrap_public"
    private_api_dns_name   = "api.test.internal"
    control_plane          = [{ subnet = "PRIVATE_A" }]
  }
  override_data {
    target = data.external.bootstrap_public_cidr
    values = { result = { operator_cidr = "198.51.100.10/32" } }
  }
  override_resource {
    target = aws_instance.control_plane
    values = { private_ip = "10.0.1.10" }
  }
  override_data {
    target = data.aws_subnets.bootstrap_public
    values = { ids = ["subnet-0123456789abcdef0"] }
  }
  override_resource {
    target = aws_lb.bootstrap_public
    values = {
      arn      = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/bootstrap/0123456789abcdef"
      dns_name = "test.elb.amazonaws.com"
    }
  }
  assert {
    condition = (
      !aws_lb.bootstrap_public[0].internal &&
      aws_lb.bootstrap_public[0].subnets == toset(["subnet-0123456789abcdef0"]) &&
      toset([for listener in aws_lb_listener.bootstrap_public : listener.port if listener.protocol == "TCP"]) == toset([50000, 6443])
    )
    error_message = "Public bootstrap needs a public NLB with two TCP passthrough listeners."
  }
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.bootstrap_public_operator) == 2 &&
      alltrue([for rule in aws_vpc_security_group_ingress_rule.bootstrap_public_operator : rule.cidr_ipv4 == "198.51.100.10/32"]) &&
      toset([for rule in aws_vpc_security_group_ingress_rule.bootstrap_public_nodes : rule.from_port]) == toset([50000, 6443]) &&
      alltrue([for target in aws_lb_target_group_attachment.bootstrap_public : target.target_id == "10.0.1.10"])
    )
    error_message = "The operator CIDR and NLB security group must gate access to the private bootstrap controller."
  }
  assert {
    condition = (
      talos_machine.control_plane[0].endpoint == "test.elb.amazonaws.com" &&
      talos_machine.control_plane[0].node == "10.0.1.10" &&
      contains(yamldecode(local.talos_api_patches[0]).machine.certSANs, "test.elb.amazonaws.com") &&
      contains(yamldecode(local.api_san_patch).certExtraSANs, "test.elb.amazonaws.com") &&
      local.cluster_endpoint == "https://api.test.internal:6443" &&
      output.bootstrap_public_host == "test.elb.amazonaws.com" &&
      output.bootstrap_public_talos_endpoint == "test.elb.amazonaws.com:50000" &&
      output.bootstrap_public_kube_url == "https://test.elb.amazonaws.com:6443" &&
      output.stable_api_hostname == null &&
      length(aws_route53_record.bootstrap_public) == 0 &&
      length(aws_lb_listener.private_talos) == 0
    )
    error_message = "Both API certificates must cover the public hostname while cluster traffic stays private."
  }
}

run "bootstrap_public_stable_hostname" {
  command = plan
  variables {
    talos_access_transport = "bootstrap_public"
    private_api_dns_name   = "api.test.example.com"
    bootstrap_public       = { dns_zone_id = "Z0123456789", operator_cidr = "198.51.100.10/32" }
  }
  override_data {
    target = data.aws_route53_zone.bootstrap_public
    values = { name = "example.com." }
  }
  override_data {
    target = data.aws_subnets.bootstrap_public
    values = { ids = ["subnet-0123456789abcdef0"] }
  }
  override_resource {
    target = aws_lb.bootstrap_public
    values = {
      arn      = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/bootstrap/0123456789abcdef"
      dns_name = "test.elb.amazonaws.com"
      zone_id  = "Z0123456789ELB"
    }
  }
  assert {
    condition = (
      output.stable_api_hostname == "api.test.example.com" &&
      output.bootstrap_public_kube_url == output.cluster_url &&
      output.bootstrap_public_talos_endpoint == "api.test.example.com:50000" &&
      talos_machine.control_plane[0].endpoint == output.stable_api_hostname &&
      aws_route53_record.bootstrap_public[0].name == output.stable_api_hostname &&
      aws_route53_record.private_api[0].name == output.stable_api_hostname &&
      one(aws_route53_record.bootstrap_public[0].alias).name == "test.elb.amazonaws.com" &&
      contains(yamldecode(local.talos_api_patches[0]).machine.certSANs, output.stable_api_hostname) &&
      contains(yamldecode(local.talos_api_patches[0]).machine.certSANs, "test.elb.amazonaws.com") &&
      contains(yamldecode(local.api_san_patch).certExtraSANs, output.stable_api_hostname)
    )
    error_message = "The public alias, both API certificates and the private record must share the stable hostname."
  }
}

run "bootstrap_public_stable_hostname_after_cutover" {
  command = plan
  variables {
    talos_access_transport           = "vpn"
    private_api_dns_name             = "api.test.example.com"
    bootstrap_public                 = { enabled = false, dns_zone_id = "Z0123456789" }
    control_plane                    = [{ subnet = "PRIVATE_A" }]
    talos_api_source_security_groups = { headscale = "sg-0123456789abcdef0" }
    talos_api_allowed_cidrs          = ["192.0.2.10/32"]
  }
  override_resource {
    target = aws_instance.control_plane
    values = { private_ip = "10.0.1.10" }
  }
  assert {
    condition = (
      output.stable_api_hostname == "api.test.example.com" &&
      output.cluster_url == "https://api.test.example.com:6443" &&
      output.bootstrap_public_host == null &&
      length(aws_route53_record.bootstrap_public) == 0 &&
      length(data.aws_route53_zone.bootstrap_public) == 0 &&
      talos_machine.control_plane[0].endpoint == output.stable_api_hostname &&
      contains(yamldecode(local.talos_api_patches[0]).machine.certSANs, output.stable_api_hostname) &&
      aws_lb_listener.private_talos[0].port == 50000 &&
      aws_lb_listener.private_talos[0].protocol == "TCP" &&
      length(aws_lb_target_group_attachment.private_talos) == 1 &&
      aws_vpc_security_group_ingress_rule.private_talos_source["headscale"].referenced_security_group_id == "sg-0123456789abcdef0" &&
      aws_vpc_security_group_ingress_rule.private_talos_cidr["192.0.2.10/32"].cidr_ipv4 == "192.0.2.10/32"
    )
    error_message = "Removing the public alias must preserve the DNS name, Talos certificate and restricted private listener."
  }
}

run "bootstrap_public_stable_hostname_rejects_unrelated_zone" {
  command = plan
  variables {
    talos_access_transport = "bootstrap_public"
    private_api_dns_name   = "api.test.example.com"
    bootstrap_public       = { dns_zone_id = "Z0123456789", operator_cidr = "198.51.100.10/32" }
  }
  override_data {
    target = data.aws_route53_zone.bootstrap_public
    values = { name = "other-example.com" }
  }
  override_data {
    target = data.aws_subnets.bootstrap_public
    values = { ids = ["subnet-0123456789abcdef0"] }
  }
  expect_failures = [data.aws_route53_zone.bootstrap_public]
}

run "bootstrap_public_vpn_retained" {
  command = plan
  variables {
    talos_access_transport = "vpn"
    private_api_dns_name   = "api.test.internal"
  }
  override_data {
    target = data.aws_security_groups.bootstrap_public_existing
    values = { ids = ["sg-0123456789abcdef0"] }
  }
  override_data {
    target = data.aws_vpc_security_group_rules.bootstrap_public_existing
    values = { ids = ["sgr-0123456789abcdef0"] }
  }
  override_data {
    target = data.aws_vpc_security_group_rule.bootstrap_public_existing
    values = {
      cidr_ipv4   = "198.51.100.10/32"
      description = "Public bootstrap operator"
      from_port   = 50000
      to_port     = 50000
      ip_protocol = "tcp"
      is_egress   = false
    }
  }
  override_data {
    target = data.aws_subnets.bootstrap_public
    values = { ids = ["subnet-0123456789abcdef0"] }
  }
  override_resource {
    target = aws_lb.bootstrap_public
    values = {
      arn      = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/bootstrap/0123456789abcdef"
      dns_name = "test.elb.amazonaws.com"
    }
  }
  assert {
    condition = (
      talos_machine.control_plane[0].endpoint == "10.0.1.10" &&
      length(aws_lb_listener.bootstrap_public) == 2 &&
      length(data.external.bootstrap_public_cidr) == 0 &&
      alltrue([for rule in aws_vpc_security_group_ingress_rule.bootstrap_public_operator : rule.cidr_ipv4 == "198.51.100.10/32"]) &&
      contains(yamldecode(local.talos_api_patches[0]).machine.certSANs, "test.elb.amazonaws.com") &&
      contains(yamldecode(local.api_san_patch).certExtraSANs, "test.elb.amazonaws.com")
    )
    error_message = "The VPN handoff must retain public access and its certificate names while changing the provider endpoint."
  }
}

run "bootstrap_public_vpn_removed" {
  command = plan
  variables {
    bootstrap_public       = { enabled = false }
    talos_access_transport = "vpn"
    private_api_dns_name   = "api.test.internal"
  }
  assert {
    condition = (
      talos_machine.control_plane[0].endpoint == "10.0.1.10" &&
      length(aws_lb.bootstrap_public) == 0 &&
      length(aws_vpc_security_group_ingress_rule.bootstrap_public_nodes) == 0 &&
      length(data.aws_security_groups.bootstrap_public_existing) == 0 &&
      output.bootstrap_public_host == null &&
      output.bootstrap_public_talos_endpoint == null &&
      output.bootstrap_public_kube_url == null
    )
    error_message = "Disabling public bootstrap must remove the load balancer and temporary ingress."
  }
}

run "bootstrap_public_without_private_dns" {
  command = plan
  variables {
    bootstrap_public       = { operator_cidr = "198.51.100.10/32" }
    talos_access_transport = "bootstrap_public"
  }
  override_resource {
    target = aws_lb.bootstrap_public
    values = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/bootstrap/0123456789abcdef" }
  }
  override_data {
    target = data.aws_subnets.bootstrap_public
    values = { ids = ["subnet-0123456789abcdef0"] }
  }
  expect_failures = [aws_instance.control_plane]
}

run "bootstrap_public_legacy_cidr" {
  command = plan
  variables {
    bootstrap_public     = { operator_cidr = "198.51.100.0/24" }
    private_api_dns_name = "api.test.internal"
  }
  override_resource {
    target = aws_lb.bootstrap_public
    values = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/bootstrap/0123456789abcdef" }
  }
  override_data {
    target = data.aws_subnets.bootstrap_public
    values = { ids = ["subnet-0123456789abcdef0"] }
  }
  assert {
    condition = (
      length(aws_lb_listener.bootstrap_public) == 2 &&
      length(data.external.bootstrap_public_cidr) == 0 &&
      alltrue([for rule in aws_vpc_security_group_ingress_rule.bootstrap_public_operator : rule.cidr_ipv4 == "198.51.100.0/24"])
    )
    error_message = "An explicit CIDR must preserve existing callers and skip public address discovery."
  }
}

run "bootstrap_public_rejects_bad_detection" {
  command = plan
  variables {
    talos_access_transport = "bootstrap_public"
    private_api_dns_name   = "api.test.internal"
  }
  override_resource {
    target = aws_lb.bootstrap_public
    values = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/bootstrap/0123456789abcdef" }
  }
  override_data {
    target = data.aws_subnets.bootstrap_public
    values = { ids = ["subnet-0123456789abcdef0"] }
  }
  override_data {
    target = data.external.bootstrap_public_cidr
    values = { result = { operator_cidr = "0.0.0.0/0" } }
  }
  expect_failures = [data.external.bootstrap_public_cidr]
}

run "bootstrap_public_rejects_unrestricted_cidr" {
  command = plan
  variables { bootstrap_public = { operator_cidr = "0.0.0.0/0" } }
  expect_failures = [var.bootstrap_public]
}

run "bootstrap_public_rejects_invalid_cidr" {
  command = plan
  variables { bootstrap_public = { operator_cidr = "invalid" } }
  expect_failures = [var.bootstrap_public]
}
