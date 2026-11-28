terraform {
  after_hook "talos_register" {
    commands = ["apply", "destroy"]
    execute = [
      "bash", "-ec",
      join("\n", [
        "set -- \"$1/scripts/pf-bootstrap-talos\" after-apply --cluster \"$TF_VAR_cluster_name\" --module \"$2\" --region \"$PF_TALOS_AWS_REGION\" --profile \"$PF_TALOS_AWS_PROFILE\"",
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
