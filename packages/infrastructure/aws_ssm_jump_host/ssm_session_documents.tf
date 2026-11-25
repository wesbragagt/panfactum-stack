locals {
  talos_destinations = var.talos_access == null ? var.talos_bootstrap : {
    kubernetes_host = var.talos_access.kubernetes.host
    controller_ips  = var.talos_access.talos.controller_ips
  }
  port_forwarding_documents = merge(var.port_forwarding_documents, local.talos_destinations == null ? {} : merge(
    {
      kube = {
        name        = "${var.cluster_name}-kube-forward"
        host        = local.talos_destinations.kubernetes_host
        port        = 6443
        description = ""
      }
    },
    {
      for index, address in local.talos_destinations.controller_ips :
      index == 0 ? "talos" : "talos-${index}" => {
        name        = index == 0 ? "${var.cluster_name}-talos-forward" : "${var.cluster_name}-talos-${index}-forward"
        host        = address
        port        = 50000
        description = ""
      }
    }
  ))
}

resource "aws_ssm_document" "api" {
  for_each = local.port_forwarding_documents

  name            = each.value.name
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = each.value.description
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
      host            = each.value.host
      portNumber      = tostring(each.value.port)
      localPortNumber = "{{ localPortNumber }}"
    }
  })
}

moved {
  from = aws_vpc_security_group_ingress_rule.kube_api
  to   = aws_vpc_security_group_ingress_rule.kube_api[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.talos_api
  to   = aws_vpc_security_group_ingress_rule.talos_api[0]
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  count                        = var.talos_access == null ? 0 : 1
  security_group_id            = var.talos_access.kubernetes.security_group_id
  referenced_security_group_id = aws_security_group.host.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
}

resource "aws_vpc_security_group_ingress_rule" "talos_api" {
  count                        = var.talos_access == null ? 0 : 1
  security_group_id            = var.talos_access.talos.security_group_id
  referenced_security_group_id = aws_security_group.host.id
  ip_protocol                  = "tcp"
  from_port                    = 50000
  to_port                      = 50000
}
