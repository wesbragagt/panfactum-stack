locals {
  redaction_patterns = jsondecode(file("${path.module}/redaction-patterns.json"))
  redaction_expressions = var.redaction_enabled ? concat(flatten([
    for category in var.redaction_categories : local.redaction_patterns[category]
  ]), var.redaction_extra_patterns) : []
  redaction_stages = templatefile("${path.module}/redaction.alloy.tftpl", {
    expressions = local.redaction_expressions
  })
}

locals {
  redaction_profile_relabel = ((var.redaction_profiles_enabled && var.redaction_enabled) ? <<-ALLOY
  rule {
    source_labels = ["__meta_kubernetes_pod_annotation_panfactum_com_log_redaction_profile"]
    regex = "(standard|strict)"
    target_label = "pf_log_redaction_profile"
    replacement = "$1"
  }
  ALLOY
  : "")
  redaction_pod_stages = "${local.redaction_stages}${templatefile("${path.module}/redaction-profiles.alloy.tftpl", {
    profiles = (var.redaction_profiles_enabled && var.redaction_enabled) ? { for profile, categories in var.redaction_profiles : profile => flatten([for category in distinct(categories) : local.redaction_patterns[category] if !contains(var.redaction_categories, category)]) } : {}
  })}"
}
