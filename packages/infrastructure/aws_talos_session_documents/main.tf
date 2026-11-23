terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

variable "cluster_name" {
  description = "Name used to scope the Session Manager document names."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", var.cluster_name))
    error_message = "The cluster name must use letters, digits, underscores or hyphens and be at most 80 characters."
  }
}

variable "controller_ip" {
  description = "Private IPv4 address allocated to the bootstrap controller."
  type        = string

  validation {
    condition     = can(cidrnetmask("${var.controller_ip}/32"))
    error_message = "The controller address must be an IPv4 address."
  }
}

resource "aws_ssm_document" "api" {
  for_each = {
    kube  = "6443"
    talos = "50000"
  }

  name            = "${var.cluster_name}-${each.key}-forward"
  document_type   = "Session"
  document_format = "JSON"

  # Only the local port is a session parameter. AWS keeps the remote host and port fixed.
  content = jsonencode({
    schemaVersion = "1.0"
    description   = "${var.cluster_name} ${each.key} API forward"
    sessionType   = "Port"
    parameters = {
      localPortNumber = {
        type           = "String"
        default        = "0"
        allowedPattern = "^([0-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
      }
    }
    properties = {
      type            = "LocalPortForwarding"
      host            = var.controller_ip
      portNumber      = each.value
      localPortNumber = "{{ localPortNumber }}"
    }
  })
}

output "document_names" {
  description = "Session Manager document names keyed by API."
  value       = { for api, document in aws_ssm_document.api : api => document.name }
}
