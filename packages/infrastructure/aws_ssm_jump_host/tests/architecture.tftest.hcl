mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-00000000000000001" }
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
    condition     = output.instance_id == "i-00000000000000001" && output.security_group_id == "sg-00000000000000001"
    error_message = "Export both IDs without creating a cluster."
  }
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
