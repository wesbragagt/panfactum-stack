mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}
mock_provider "tailscale" {}

override_resource {
  target = aws_launch_template.router
  values = { id = "lt-0000000000000000a" }
}

override_resource {
  target = aws_iam_instance_profile.router
  values = { arn = "arn:aws:iam::000000000000:instance-profile/test" }
}
mock_provider "pf" {}

variables {
  vpc_id                        = "vpc-00000000"
  advertised_routes             = ["10.0.64.0/18"]
  tailscale_oauth_client_secret = "tskey-client-test"
}

run "single_router_by_default" {
  command = plan
  assert {
    condition     = output.hostnames == ["tailscale-subnet-router-public-a"]
    error_message = "Expected one router in PUBLIC_A."
  }
  assert {
    condition     = output.advertised_routes == tolist(["10.0.64.0/18"])
    error_message = "No resolver route without split DNS."
  }
}

run "ha_runs_two_azs_and_adds_resolver_route" {
  command = plan
  variables {
    ha_enabled        = true
    split_dns_domains = ["cluster.internal"]
  }
  assert {
    condition     = length(aws_autoscaling_group.router) == 2
    error_message = "Expected one ASG per AZ."
  }
  assert {
    condition     = output.advertised_routes == tolist(["10.0.64.0/18", "10.0.0.2/32"])
    error_message = "Expected the VPC resolver route."
  }
  assert {
    condition     = tailscale_dns_split_nameservers.vpc["cluster.internal"].nameservers == toset(["10.0.0.2"])
    error_message = "Split DNS must point at the VPC resolver."
  }
}
