terraform {
  before_hook "cilium_helm_provider" {
    commands = concat(get_terraform_commands_that_need_vars(), ["init", "validate", "test", "graph"])
    # NOTE: Panfactum selects the connection settings. Helm 3 needs object syntax for those settings.
    execute = ["bash", "-ec", <<-SCRIPT
      if [[ -f helm.tf ]]; then
        sed -i 's/^\([[:space:]]*\)kubernetes[[:space:]]*{/\1kubernetes = {/' helm.tf
      fi
    SCRIPT
    ]
  }
}

generate "cilium_kubernetes_override" {
  path      = "cilium_kubernetes_override.tf"
  if_exists = "overwrite_terragrunt"
  # NOTE: Cilium manages its operator's IRSA annotation directly.
  contents = <<-HCL
    provider "kubernetes" {
      ignore_annotations = []
      ignore_labels      = []
    }
  HCL
}
