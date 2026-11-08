locals {
  redaction_patterns = jsondecode(file("${path.module}/redaction-patterns.json"))
  redaction_expressions = var.redaction_enabled ? concat(flatten([
    for category in var.redaction_categories : local.redaction_patterns[category]
  ]), var.redaction_extra_patterns) : []
  redaction_stages = templatefile("${path.module}/redaction.alloy.tftpl", {
    expressions = local.redaction_expressions
  })
}
