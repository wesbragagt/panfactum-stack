mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
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
