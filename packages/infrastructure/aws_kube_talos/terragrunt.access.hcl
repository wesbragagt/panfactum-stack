terraform {
  before_hook "talos_tunnel" {
    commands = ["plan", "apply", "destroy"]
    execute = [
      "bash", "-ec",
      join("\n", [
        "case \"$${TF_VAR_talos_access_transport:-$PF_TALOS_TRANSPORT}\" in vpn|bootstrap_public) exit 0 ;; esac",
        "access=\"$1/scripts/cluster_access.py\"",
        "shift",
        "set -- --transport ssm --cluster \"$TF_VAR_cluster_name\" --profile \"$PF_TALOS_AWS_PROFILE\" --region \"$PF_TALOS_AWS_REGION\" --module \"$1\"",
        "python3 \"$access\" --talos-config \"$@\"",
        "exec python3 \"$access\" --ensure \"$@\"",
      ]),
      "talos_tunnel", get_parent_terragrunt_dir("talos_access"), get_original_terragrunt_dir(),
    ]
  }

  after_hook "talos_register" {
    commands = ["apply"]
    execute = [
      "bash", "-ec",
      join("\n", [
        "cd \"$2\"",
        "set -- \"$1/scripts/pf-bootstrap-talos\" register --cluster \"$TF_VAR_cluster_name\" --module \"$2\" --region \"$PF_TALOS_AWS_REGION\" --profile \"$PF_TALOS_AWS_PROFILE\" --kube-port \"$${PF_TALOS_KUBE_PORT:-16443}\" --talos-port \"$${PF_TALOS_PORT:-50000}\"",
        "if [ \"$${TF_VAR_talos_access_transport:-$PF_TALOS_TRANSPORT}\" = bootstrap_public ]; then set -- \"$@\" --bootstrap-public; fi",
        "exec python3 \"$@\"",
      ]),
      "talos_register", get_parent_terragrunt_dir("talos_access"), get_original_terragrunt_dir(),
    ]
    run_on_error = false
  }
}

inputs = {
  etcd_pre_membership_snapshot_kubeconfig = get_env("KUBECONFIG", "") == "" ? null : get_env("KUBECONFIG")
}
