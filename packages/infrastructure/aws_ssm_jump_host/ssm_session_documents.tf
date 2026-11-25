resource "aws_ssm_document" "api" {
  for_each = var.port_forwarding_documents

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
