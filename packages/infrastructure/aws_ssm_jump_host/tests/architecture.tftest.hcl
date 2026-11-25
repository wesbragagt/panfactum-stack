mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      vpc_id               = "vpc-00000000000000001"
      availability_zone_id = "use2-az1"
    }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

variables {
  cluster_name = "test"
  vpc_id       = "vpc-00000000000000001"
  subnet_id    = "subnet-00000000000000001"
}

run "private_ssm_host_has_its_own_identity_and_security_group" {
  command = plan

  override_resource {
    target = aws_instance.host
    values = { id = "i-00000000000000001" }
  }

  override_resource {
    target = aws_security_group.host
    values = { id = "sg-00000000000000001" }
  }

  assert {
    condition     = aws_instance.host.tags["Name"] == "test-ssm-tunnel" && aws_instance.host.instance_type == "t4g.nano"
    error_message = "Name the arm64 jump host for its cluster."
  }
  assert {
    condition     = aws_instance.host.subnet_id == var.subnet_id && aws_instance.host.associate_public_ip_address == false && aws_security_group.host.vpc_id == var.vpc_id && length(aws_security_group.host.ingress) == 0
    error_message = "The host must stay in the supplied private subnet without a public IP or inbound security rules."
  }
  assert {
    condition     = aws_instance.host.metadata_options[0].http_tokens == "required" && aws_instance.host.metadata_options[0].http_put_response_hop_limit == 1 && aws_instance.host.root_block_device[0].encrypted
    error_message = "The host must require IMDSv2 and encrypt the root volume."
  }
  assert {
    condition     = aws_instance.host.iam_instance_profile == aws_iam_instance_profile.host.name && aws_iam_instance_profile.host.role == aws_iam_role.host.name && aws_iam_role_policy_attachment.ssm.role == aws_iam_role.host.name && aws_iam_role_policy_attachment.ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "The host's IAM profile must include the SSM agent permissions."
  }
  assert {
    condition     = alltrue([for name in [aws_iam_role.host.name, aws_iam_instance_profile.host.name, aws_security_group.host.name] : name == "test-ssm-tunnel"])
    error_message = "Keep the existing role, profile and security group names by default."
  }
  assert {
    condition     = output.instance_id == "i-00000000000000001" && length(output.instance_ids) == 1 && output.instance_ids[0] == output.instance_id && output.security_group_id == "sg-00000000000000001"
    error_message = "Export both IDs without creating a cluster."
  }
  assert {
    condition     = length(aws_instance.secondary) == 0 && length(aws_ssm_document.api) == 0 && length(output.document_names) == 0 && length(output.document_destinations) == 0
    error_message = "The second host and port forwarding documents must be opt-in."
  }
}

run "port_forwarding_documents_fix_remote_destination" {
  command = plan
  variables {
    port_forwarding_documents = {
      kube = {
        name        = "operator-canary-kube-forward"
        host        = "10.0.128.20"
        port        = 6443
        description = "operator-canary kube API forward"
      }
      talos = {
        name        = "operator-canary-talos-forward"
        host        = "10.0.128.20"
        port        = 50000
        description = "operator-canary talos API forward"
      }
    }
  }
  assert {
    condition = alltrue([
      for api, port in { kube = "6443", talos = "50000" } :
      aws_ssm_document.api[api].name == "operator-canary-${api}-forward"
      && output.document_names[api] == "operator-canary-${api}-forward"
      && aws_ssm_document.api[api].document_type == "Session"
      && aws_ssm_document.api[api].document_format == "JSON"
      && jsondecode(aws_ssm_document.api[api].content).description == "operator-canary ${api} API forward"
      && jsondecode(aws_ssm_document.api[api].content).sessionType == "Port"
      && jsondecode(aws_ssm_document.api[api].content).properties.host == "10.0.128.20"
      && jsondecode(aws_ssm_document.api[api].content).properties.portNumber == port
      && jsondecode(aws_ssm_document.api[api].content).properties.localPortNumber == "{{ localPortNumber }}"
      && jsondecode(aws_ssm_document.api[api].content).parameters == {
        localPortNumber = {
          type           = "String"
          default        = "0"
          allowedPattern = "^([0-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
        }
      }
    ])
    error_message = "Each document must pin its destination and expose only the validated local port."
  }
}

run "two_private_hosts_share_fixed_documents" {
  command = plan

  variables {
    secondary_subnet_id = "subnet-00000000000000002"
    resource_name       = "test-standalone-ssm-tunnel"
    port_forwarding_documents = {
      kube = {
        name = "test-kube-forward"
        host = "api.test.internal"
        port = 6443
      }
      talos-a = {
        name = "test-talos-a-forward"
        host = "10.0.128.20"
        port = 50000
      }
      talos-b = {
        name = "test-talos-b-forward"
        host = "10.0.192.20"
        port = 50000
      }
    }
  }

  override_data {
    target = data.aws_subnet.secondary
    values = {
      vpc_id               = "vpc-00000000000000001"
      availability_zone_id = "use2-az2"
    }
  }

  override_resource {
    target = aws_instance.host
    values = { id = "i-00000000000000001" }
  }

  override_resource {
    target = aws_instance.secondary
    values = { id = "i-00000000000000002" }
  }

  override_resource {
    target = aws_security_group.host
    values = { id = "sg-00000000000000001" }
  }

  assert {
    condition = (
      length(aws_instance.secondary) == 1
      && aws_instance.host.subnet_id == var.subnet_id
      && aws_instance.secondary[0].subnet_id == var.secondary_subnet_id
      && data.aws_subnet.selected.availability_zone_id != data.aws_subnet.secondary[0].availability_zone_id
      && output.instance_ids[0] == output.instance_id
      && output.instance_ids[1] == "i-00000000000000002"
    )
    error_message = "Add one secondary host in a distinct AZ while retaining the primary as the first approved instance."
  }

  assert {
    condition = (
      aws_instance.secondary[0].vpc_security_group_ids == aws_instance.host.vpc_security_group_ids
      && aws_instance.secondary[0].iam_instance_profile == aws_instance.host.iam_instance_profile
      && aws_instance.secondary[0].associate_public_ip_address == false
      && aws_instance.secondary[0].metadata_options[0].http_tokens == "required"
      && aws_instance.secondary[0].root_block_device[0].encrypted
      && aws_instance.secondary[0].tags == aws_instance.host.tags
      && aws_instance.secondary[0].tags["Name"] == "test-ssm-tunnel"
      && aws_instance.secondary[0].tags["panfactum.com/module"] == "aws_ssm_jump_host"
      && aws_instance.secondary[0].tags["panfactum.com/cluster"] == var.cluster_name
    )
    error_message = "The secondary must share the primary security group, IAM profile and exact discovery tags, with encrypted storage and no public IP."
  }

  assert {
    condition     = alltrue([for name in [aws_iam_role.host.name, aws_iam_instance_profile.host.name, aws_security_group.host.name] : name == var.resource_name])
    error_message = "Allow a standalone jump pair alongside an existing embedded host without changing discovery tags."
  }

  assert {
    condition = length(aws_ssm_document.api) == 3 && alltrue([
      for key, destination in var.port_forwarding_documents :
      output.document_destinations[key] == { name = destination.name, host = destination.host, port = destination.port }
      && jsondecode(aws_ssm_document.api[key].content).properties.host == destination.host
      && jsondecode(aws_ssm_document.api[key].content).properties.portNumber == tostring(destination.port)
    ])
    error_message = "Share one Kubernetes document and one document per Talos destination across both hosts."
  }
}

run "reject_secondary_subnet_in_the_primary_az" {
  command = plan
  variables { secondary_subnet_id = "subnet-00000000000000002" }
  expect_failures = [data.aws_subnet.secondary]
}

run "reject_secondary_subnet_in_another_vpc" {
  command = plan
  variables { secondary_subnet_id = "subnet-00000000000000002" }
  override_data {
    target = data.aws_subnet.secondary
    values = {
      vpc_id               = "vpc-00000000000000002"
      availability_zone_id = "use2-az2"
    }
  }
  expect_failures = [data.aws_subnet.secondary]
}

run "reject_subnet_in_another_vpc" {
  command = plan
  variables { vpc_id = "vpc-00000000000000002" }
  expect_failures = [data.aws_subnet.selected]
}

run "reject_x86_instance_type" {
  command = plan
  variables { instance_type = "t3.nano" }
  override_data {
    target = data.aws_ec2_instance_type.host
    values = { supported_architectures = ["x86_64"] }
  }
  expect_failures = [data.aws_ec2_instance_type.host]
}

run "talos_bootstrap_generates_fixed_documents_without_api_security_groups" {
  command = plan

  variables {
    talos_bootstrap = {
      kubernetes_host = "api.test.internal"
      controller_ips  = ["10.0.128.10", "10.0.192.10"]
    }
  }

  override_resource {
    target = aws_instance.host
    values = { id = "i-00000000000000001" }
  }

  override_resource {
    target = aws_security_group.host
    values = { id = "sg-00000000000000001" }
  }

  assert {
    condition     = output.instance_ids == ["i-00000000000000001"] && output.security_group_id == "sg-00000000000000001"
    error_message = "Export the private jump host identity and source security group before deploying Talos."
  }

  assert {
    condition = output.document_destinations == {
      kube      = { name = "test-kube-forward", host = "api.test.internal", port = 6443 }
      talos     = { name = "test-talos-forward", host = "10.0.128.10", port = 50000 }
      "talos-1" = { name = "test-talos-1-forward", host = "10.0.192.10", port = 50000 }
    }
    error_message = "Export the fixed document name, host and port for each planned destination."
  }

  assert {
    condition = alltrue([
      for key, destination in output.document_destinations :
      jsondecode(aws_ssm_document.api[key].content).properties.host == destination.host
      && jsondecode(aws_ssm_document.api[key].content).properties.portNumber == tostring(destination.port)
      && keys(jsondecode(aws_ssm_document.api[key].content).parameters) == ["localPortNumber"]
    ])
    error_message = "Fix every remote address and port in its document and expose only the local port to operators."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.kube_api) == 0 && length(aws_vpc_security_group_ingress_rule.talos_api) == 0
    error_message = "Leave both destination ingress rules for the Talos deployment."
  }
}

run "talos_access_preserves_two_host_documents_and_ingress" {
  command = plan

  variables {
    cluster_name        = "homelab-talos-2"
    resource_name       = "homelab-talos-2-standalone-ssm-tunnel"
    secondary_subnet_id = "subnet-00000000000000002"
    talos_access = {
      kubernetes = {
        host              = "api.homelab-talos-2.internal"
        security_group_id = "sg-00000000000000002"
      }
      talos = {
        controller_ips    = ["10.0.128.10", "10.0.64.10", "10.0.192.10"]
        security_group_id = "sg-00000000000000003"
      }
    }
  }

  override_data {
    target = data.aws_subnet.secondary
    values = {
      vpc_id               = "vpc-00000000000000001"
      availability_zone_id = "use2-az2"
    }
  }

  override_resource {
    target = aws_security_group.host
    values = { id = "sg-00000000000000001" }
  }

  assert {
    condition = output.document_destinations == {
      kube      = { name = "homelab-talos-2-kube-forward", host = "api.homelab-talos-2.internal", port = 6443 }
      talos     = { name = "homelab-talos-2-talos-forward", host = "10.0.128.10", port = 50000 }
      "talos-1" = { name = "homelab-talos-2-talos-1-forward", host = "10.0.64.10", port = 50000 }
      "talos-2" = { name = "homelab-talos-2-talos-2-forward", host = "10.0.192.10", port = 50000 }
    }
    error_message = "Retain the Talos-2 document keys, names, destinations and ports."
  }

  assert {
    condition = (
      length(output.instance_ids) == 2
      && length(aws_vpc_security_group_ingress_rule.kube_api) == 1
      && length(aws_vpc_security_group_ingress_rule.talos_api) == 1
      && aws_vpc_security_group_ingress_rule.kube_api[0].security_group_id == "sg-00000000000000002"
      && aws_vpc_security_group_ingress_rule.kube_api[0].referenced_security_group_id == output.security_group_id
      && aws_vpc_security_group_ingress_rule.kube_api[0].from_port == 6443
      && aws_vpc_security_group_ingress_rule.kube_api[0].to_port == 6443
      && aws_vpc_security_group_ingress_rule.talos_api[0].security_group_id == "sg-00000000000000003"
      && aws_vpc_security_group_ingress_rule.talos_api[0].referenced_security_group_id == output.security_group_id
      && aws_vpc_security_group_ingress_rule.talos_api[0].from_port == 50000
      && aws_vpc_security_group_ingress_rule.talos_api[0].to_port == 50000
    )
    error_message = "Retain both jump hosts and exactly one destination ingress rule per API."
  }
}
