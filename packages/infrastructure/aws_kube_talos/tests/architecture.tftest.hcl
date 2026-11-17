mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}
mock_provider "talos" {}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { jwks_json = "{}" } }
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
  cluster_name = "test"
  vpc_id       = "vpc-00000000"
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
