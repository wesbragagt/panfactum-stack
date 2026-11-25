mock_provider "aws" {
  mock_data "aws_route53_zone" {
    defaults = { name = "example.com." }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000" }
  }
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
  backend                       = "tailscale"
  vpc_id                        = "vpc-00000000"
  advertised_routes             = ["10.0.64.0/18"]
  tailscale_oauth_client_secret = "tskey-client-test"
}

run "single_router_by_default" {
  command = plan
  assert {
    condition     = length(aws_route53_record.managed_headscale) == 0 && length(aws_instance.headscale) == 0 && output.hostnames == ["tailscale-subnet-router-public-a"]
    error_message = "Expected one router in PUBLIC_A."
  }
  assert {
    condition     = output.advertised_routes == tolist(["10.0.64.0/18"])
    error_message = "No resolver route without split DNS."
  }
  assert {
    condition = length(aws_autoscaling_group.router) == 1 && alltrue([
      for router in aws_autoscaling_group.router :
      router.min_size == 1 && router.max_size == 1 && router.desired_capacity == 1
    ])
    error_message = "Expected exactly one ASG with one instance."
  }
}

run "single_router_boot_configuration" {
  command = plan
  variables {
    split_dns_domains = ["homelab-talos-2.internal"]
  }
  assert {
    condition     = output.advertised_routes == tolist(["10.0.64.0/18", "10.0.0.2/32"])
    error_message = "Expected the VPC resolver route."
  }
  assert {
    condition = alltrue([
      for router in aws_launch_template.router :
      !strcontains(base64decode(router.user_data), var.tailscale_oauth_client_secret) &&
      strcontains(base64decode(router.user_data), "--name /tailscale-subnet-router/tailscale-oauth-client-secret") &&
      strcontains(base64decode(router.user_data), "tailscale-1.104.7-1") &&
      strcontains(base64decode(router.user_data), "file:$auth_file") &&
      strcontains(base64decode(router.user_data), "--advertise-routes=10.0.64.0/18,10.0.0.2/32") &&
      !strcontains(base64decode(router.user_data), "--advertise-exit-node") &&
      !strcontains(base64decode(router.user_data), "--accept-routes")
    ])
    error_message = "Boot configuration must reference only the SSM parameter and intended routes."
  }
  assert {
    condition = alltrue([
      for router in aws_launch_template.router :
      one(router.block_device_mappings).device_name == "/dev/xvda" &&
      one(one(router.block_device_mappings).ebs).encrypted
    ])
    error_message = "The root EBS volume must be encrypted."
  }
}

run "enrollment_parameter_policy" {
  command = apply
  assert {
    condition = toset([for statement in data.aws_iam_policy_document.router.statement : statement.effect]) == toset(["Allow", "Deny"]) && alltrue([
      for statement in data.aws_iam_policy_document.router.statement :
      statement.effect == "Deny" ? (
        statement.actions == toset(["ssm:GetParameter", "ssm:GetParameters"]) &&
        statement.not_resources == toset([aws_ssm_parameter.oauth_secret[0].arn])
        ) : (
        statement.actions == toset(["ssm:GetParameter"]) &&
        statement.resources == toset([aws_ssm_parameter.oauth_secret[0].arn])
      )
    ])
    error_message = "The router credential policy must permit only its enrollment parameter."
  }
}

run "ha_runs_two_azs_and_adds_resolver_route" {
  command = plan
  variables {
    ha_enabled        = true
    split_dns_domains = ["homelab-talos-2.internal"]
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
    condition     = tailscale_dns_split_nameservers.vpc["homelab-talos-2.internal"].nameservers == toset(["10.0.0.2"])
    error_message = "Split DNS must point at the VPC resolver."
  }
}

run "managed_headscale_dedicated" {
  command = apply

  variables {
    ha_enabled        = true
    split_dns_domains = ["homelab-talos-2.internal"]
    backend = "headscale"
    headscale = {
      hostname  = "headscale.example.com"
      zone_id   = "Z123"
    }
  }

  override_resource {
    target = aws_eip.headscale
    values = { public_ip = "203.0.113.10" }
  }

  assert {
    condition     = output.managed_headscale == { login_server = "https://headscale.example.com", instance_id = aws_instance.headscale[0].id } && length(aws_autoscaling_group.router) == 2
    error_message = "Dedicated mode uses one Headscale server and retains HA router groups."
  }

  assert {
    condition     = !aws_route53_record.managed_headscale[0].allow_overwrite && aws_route53_record.managed_headscale[0].name == "headscale.example.com" && aws_route53_record.managed_headscale[0].records == toset(["203.0.113.10"]) && aws_eip_association.headscale[0].instance_id == aws_instance.headscale[0].id
    error_message = "The public hostname must use the server's stable EIP."
  }

  assert {
    condition     = aws_ebs_volume.headscale[0].encrypted && aws_volume_attachment.headscale[0].instance_id == aws_instance.headscale[0].id
    error_message = "Server state must live on a separate encrypted volume."
  }

  assert {
    condition = alltrue([
      for router in aws_launch_template.router :
      strcontains(base64decode(router.user_data), "--name /tailscale-subnet-router/headscale-router-enrollment") &&
      strcontains(base64decode(router.user_data), "--login-server='https://headscale.example.com'")
    ]) && length(aws_ssm_parameter.oauth_secret) == 0 && length(tailscale_dns_split_nameservers.vpc) == 0
    error_message = "Routers must enroll with a server-issued key and Headscale controls split DNS."
  }
}


run "headscale_rejects_other_zone" {
  command = plan

  variables {
    backend = "headscale"
    headscale = {
      hostname = "headscale.other.example"
      zone_id  = "Z123"
    }
  }

  expect_failures = [aws_route53_record.managed_headscale]
}




run "rejects_invalid_backend" {
  command = plan
  variables { backend = "invalid" }
  expect_failures = [var.backend]
}

run "headscale_requires_configuration" {
  command = plan
  variables { backend = "headscale" }
  expect_failures = [aws_security_group.router]
}

run "tailscale_rejects_headscale_configuration" {
  command = plan
  variables {
    backend = "tailscale"
    headscale = {
      hostname = "headscale.example.com"
      zone_id = "Z123"
    }
  }
  expect_failures = [aws_security_group.router]
}
