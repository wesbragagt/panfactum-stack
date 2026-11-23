mock_provider "aws" {}

run "fixed_destinations" {
  command = plan

  variables {
    cluster_name  = "operator-canary"
    controller_ip = "10.0.128.20"
  }

  assert {
    condition = alltrue([
      for api, port in { kube = "6443", talos = "50000" } :
      aws_ssm_document.api[api].name == "operator-canary-${api}-forward"
      && jsondecode(aws_ssm_document.api[api].content).properties.host == "10.0.128.20"
      && jsondecode(aws_ssm_document.api[api].content).properties.portNumber == port
      && keys(jsondecode(aws_ssm_document.api[api].content).parameters) == ["localPortNumber"]
    ])
    error_message = "The documents must pin controller and API port, and expose only the caller's local port."
  }
}
