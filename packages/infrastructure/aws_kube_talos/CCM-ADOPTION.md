# Move an existing AWS CCM release into Talos state

Use this procedure for a Talos cluster with an active standalone
`kube_aws_ccm` caller. New clusters can enable `aws_ccm` before the first
`aws_kube_talos` apply.

1. Pause applies to both Terragrunt units. Pull their states into a
   mode-0700 directory and keep immutable copies. Record the state lineages
   and serials, release revision, live ConfigMap, IAM role and policy ARNs,
   and CCM leader. Use the target Kubernetes context when inspecting the release.
2. Set the Talos `aws_ccm` input with the deployed image and
   `host_networking = false`. Preserve the effective legacy Helm values,
   topology, IAM tags and IP restrictions using the adoption overrides only
   where needed. Use the current ConfigMap's subnet and availability zone
   if they differ from the bootstrap controller's placement. Keep the
   Kubernetes operator API available for the standalone and Talos providers.
3. On writable copies of both states, transfer each managed address with
   `tofu state mv -state=ccm.tfstate -state-out=talos.tfstate "<address>" "module.aws_ccm[0].<address>"`
   from an empty local directory. Include `helm_release.ccm`,
   `kubernetes_config_map_v1.cloud` and all managed entries under
   `module.aws_permissions`, including optional policies and attachments.
   Compare the copied states with the originals. Check that both original
   lineages remain and each resource has one binding. Recheck both remote
   serials. Push the destination and then the source with locking enabled.
   Keep both units paused until both pushes and verification succeed.
4. Plan Talos in a new tmux window. Require zero live changes and check
   the same Helm revision, ConfigMap UID and IAM ARNs. If one push fails,
   compare both remote states before any apply. Complete the missing push
   after verifying serials or reverse the transfers whose pushes succeeded.
   Use freshly pulled states for reversal so the state serial advances.
5. Retire the standalone caller and replace any ordering edges to it with
   the existing Talos dependency. Enable host networking in a separate
   reviewed plan. Verify CCM leadership, the controller provider IDs and
   cloud initialization taints, then replan Talos and its direct dependents.

Keep the original release and ConfigMap during the handoff. A Helm uninstall
deletes the running CCM. Use the destination for subsequent rollouts only
after both backends reflect the transfer. See
[OpenTofu state moves](https://opentofu.org/docs/cli/state/mv/).
