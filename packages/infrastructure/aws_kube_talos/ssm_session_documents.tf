variable "ssm_session_documents_enabled" {
  description = "Create Session Manager documents that forward each API to the bootstrap controller's fixed private IPv4 address."
  type        = bool
  default     = false
}

locals {
  ssm_session_controller_ip = try(var.control_plane_private_ips[local.bootstrap_index], null)
}

resource "aws_ssm_document" "api" {
  for_each = var.ssm_session_documents_enabled ? {
    kube  = "6443"
    talos = "50000"
  } : {}

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
      host            = local.ssm_session_controller_ip
      portNumber      = each.value
      localPortNumber = "{{ localPortNumber }}"
    }
  })

  lifecycle {
    precondition {
      condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", var.cluster_name))
      error_message = "The cluster name must use letters, digits, underscores or hyphens and be at most 80 characters."
    }
    precondition {
      condition     = can(cidrnetmask("${local.ssm_session_controller_ip}/32"))
      error_message = "ssm_session_documents_enabled requires an IPv4 address in control_plane_private_ips for the bootstrap controller."
    }
  }
}
