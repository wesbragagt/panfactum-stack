# aws_kube_talos improvement checklist

Source: control-plane and node/network reviews comparing this module with Panfactum `aws_eks` (2026-10-27). Work top to bottom. Each item lists where to change and how to prove it is done.

## 1. Backups you can trust

- [ ] **Allow multipart uploads.** Remove the `RequireKMS` and `RequireBackupKey` deny statements (`backup.tf:107-115`); default bucket encryption already enforces the key. Optional: keep a deny that fires only when the key-id header is present and wrong (`Null` + `StringNotEquals`).
  - Done when: a snapshot larger than 8 MiB uploads in real AWS.
- [ ] **Alert on stale backups.** Alarm when the newest object under `etcd/<cluster>/` is older than 1 hour (EventBridge schedule + Lambda, or CloudWatch metric on S3 events).
  - Done when: stopping the CronJob triggers the alert.
- [ ] **Never expire the last good snapshot.** Also write a fixed `latest.snapshot` key and keep N noncurrent versions with `newer_noncurrent_versions` (`backup.tf:74-79`).
  - Done when: a 60-day backup outage still leaves a restorable snapshot.
- [ ] **Store the Talos secrets bundle outside Terraform state.** Export `talos_machine_secrets` in `talosctl gen secrets` format, SOPS-encrypted in the repo (`main.tf:205`).
  - Done when: a restore succeeds using only the repo, S3, and KMS access.
- [ ] **Write `RESTORE.md`.** Cover multi-node loss, new IPs, `bootstrap --recover-from`, and removing stale etcd members.
  - Done when: the runbook is followed once on real AWS.
- [ ] **Make the backup job self-contained.** Use a pinned image digest containing `talosctl` and `awscli` instead of downloading both every run (`backup.tf:155-168`). Fail validation if `talos_version` does not match the checksum map (`vars.tf`).
  - Done when: the CronJob succeeds with GitHub and PyPI blocked.
- [ ] **Deliver backup manifest changes to the cluster.** Manage the CronJob with the kubernetes provider, or document `talosctl upgrade-k8s` as required after changes (inline manifests only apply at bootstrap).
  - Done when: rotating the IAM key reaches the running Secret.
- [ ] **Prove the in-cluster path.** Run `kubectl -n etcd-backup create job --from=cronjob/etcd-backup first-run` after apply.
  - Done when: the job uploads an SSE-KMS object to the real bucket.

## 2. Control plane resilience

- [ ] **Leave etcd gracefully on destroy.** Add `on_destroy = { reset = true, graceful = true, reboot = false }` to `talos_machine_configuration_apply.control_plane` (`main.tf:304`).
  - Done when: replacing one control plane leaves exactly 3 healthy etcd members.
- [ ] **Guard against losing quorum.** Precondition that blocks lowering `control_plane_count` unless an explicit flag is set (`vars.tf:23-32`).
- [ ] **Protect the PKI and instances.** `prevent_destroy` on `talos_machine_secrets.this` and `aws_instance.control_plane`; `disable_api_termination = true` on control planes.
- [ ] **Place control planes by subnet name, not sorted ID.** Look up subnets per name and assert one per AZ (`main.tf:39-48`, `main.tf:243`).
  - Done when: adding a subnet does not plan any control-plane replacement.
- [ ] **Roll changes one node at a time.** Document the upgrade order (bump vars, apply per node, `talosctl upgrade` / `upgrade-k8s`) so Terraform never rolls back live versions (`main.tf:214-226`).
- [ ] **Health-check the API properly.** Change the NLB target group to HTTPS on `/readyz` (`main.tf:173-176`).
- [ ] **Stop pinning operations to `control_plane[0]`.** Bootstrap and kubeconfig resources should tolerate that node being gone (`main.tf:320-334`).

## 3. Workloads stay up

- [ ] **Run always-on capacity across zones.** At least 2-3 on-demand workers in an ASG across AZs, or allow scheduling on control planes (`vars.tf` `worker_count`, `main.tf:270`).
  - Done when: terminating any single node keeps CoreDNS and workloads running.
- [ ] **Give pods AWS credentials (IRSA).** Public OIDC issuer for the Talos service-account issuer, `aws_iam_openid_connect_provider`, pod-identity webhook, and a fork of `kube_sa_auth_aws` that takes the issuer as input.
  - Done when: a pod assumes an IAM role via a projected token.
- [ ] **Add the AWS cloud controller manager.** Enable `cluster.externalCloudProvider`; nodes get `providerID` and zone labels.
- [ ] **Make Karpenter work on Talos.** Node role and instance profile, sensitive output of the worker machine config, node pools with `amiFamily: Custom` selecting the Talos arm64 AMI and node SG.
  - Done when: Karpenter launches a Spot worker that joins and runs a pod.
- [ ] **Persistent volumes.** Deploy EBS CSI once IRSA works.
  - Done when: a PVC binds and survives pod rescheduling.
- [ ] **Choose the CNI before workloads land.** Either keep Flannel or set `cni: none` + `proxy.disabled: true` and install Cilium (`main.tf:206-228`).

## 4. Network and security

- [ ] **Move nodes to private subnets.** Use the existing NAT, tag subnets `kubernetes.io/cluster/<name>`, drop per-node public IPs (`main.tf:245,276`).
- [ ] **Use an internal NLB for nodes.** Allow nodes by security-group reference instead of public IPs; remove the `lb_nodes` rule (`main.tf:128-137`).
- [ ] **Reach control planes by private IP.** Set talosconfig `nodes` to private IPs (`main.tf:337-340`). Use EIPs or a bastion for operator access.
- [ ] **Remove PKI from EC2 user data.** Boot with a minimal config and push the full config over the Talos API (`main.tf:246`). Fix the misleading comment at `main.tf:248`.
  - Done when: `DescribeInstanceAttribute userData` contains no private keys.
- [ ] **Rotate the backup credential.** Replace the static IAM user key with IRSA once available (`backup.tf:148-150`).

## 5. Cost and capacity

- [ ] **Recalculate cost after the network changes.** Target: no per-node public IPv4, internal NLB, workloads on control planes or Spot workers. Compare with Panfactum EKS (~$147/mo on-demand, ~$100 with Spot controllers).
- [ ] **Grow root volumes.** Raise `root_volume_size_gb` above 20 GB; etcd and container images share it.
- [ ] **Optional: cross-region backup copy.** Replicate the bucket or add Object Lock.

## Decision gate

- [ ] After sections 1-2, decide whether to continue with Talos or return to `aws_eks`. Section 3 requires forking several Panfactum modules.
