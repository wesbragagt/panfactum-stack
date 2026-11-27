terraform {
  before_hook "talos_tunnel" {
    commands = ["plan", "apply", "destroy"]
    # A direct launch makes Terragrunt the parent and resolves the script inside the downloaded module.
    execute = ["python3", "scripts/cluster_access.py", "--bootstrap", "--background", "--terragrunt-hook"]
  }
}
