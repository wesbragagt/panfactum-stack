terraform {
  before_hook "ccm_helm_provider" {
    commands = concat(get_terraform_commands_that_need_vars(), ["init", "validate", "test", "graph"])
    # NOTE: The shared Helm provider template uses Helm 2 nested syntax.
    execute = ["bash", "-ec", <<-SCRIPT
      if [[ -f helm.tf ]]; then
        sed -i 's/^\([[:space:]]*\)kubernetes[[:space:]]*{/\1kubernetes = {/' helm.tf
      fi
    SCRIPT
    ]
  }
}
