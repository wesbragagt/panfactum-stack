# Talos etcd backup test

Proves that the digest-pinned Sidero `talos-backup` container produces a snapshot that can rebuild a lost control plane. Everything runs locally: a Talos cluster in Docker and [Floci](https://github.com/floci-io/floci) as the AWS S3 and KMS emulator. No real AWS account is touched.

## Requirements

- Docker
- Python 3, `aws` CLI v2, `kubectl` (all in the repo dev shell)
- Network access to pull `ghcr.io/siderolabs/talos`, the Floci image, and `talosctl` if the shell's version differs

## Run

```bash
python3 packages/infrastructure/aws_kube_talos/tests/bootstrap.py --directory /tmp/etcd-smoke
python3 packages/infrastructure/aws_kube_talos/tests/test.py --directory /tmp/etcd-smoke
python3 packages/infrastructure/aws_kube_talos/tests/cleanup.py --directory /tmp/etcd-smoke
```

`bootstrap.py` options: `--port` (Floci host port, default `14566`) and `--subnet` (Docker subnet, default `10.87.241.0/24`). Change them if they collide with something already running.

All credentials, kubeconfig, and talosconfig live in the `--directory`, which is created with mode `0700`. The scripts never read your AWS profile, `~/.kube/config`, or `~/.talos/config`.

## What `test.py` checks

1. Creates a talosconfig limited to the `os:etcd:backup` role, the same role the in-cluster CronJob gets, and confirms it cannot read the machine config.
2. Writes ConfigMap `dr-marker`, runs the production backup container, then writes ConfigMap `dr-after-backup`.
3. Confirms the bucket default selects the backup KMS key, then downloads the uploaded snapshot.
4. Saves the node's machine config, destroys the cluster, and starts a replacement node with the same config.
5. Runs `talosctl bootstrap --recover-from` with the downloaded snapshot.
6. Passes only if `dr-marker` is restored with its value and `dr-after-backup` is absent.

## Limits

- Floci stores the bucket encryption configuration but does not apply it to object metadata or encrypt at rest. It does not enforce IAM and KMS policies. The policy truth table has offline coverage; AWS enforcement still needs a real AWS test.
- The test runs the production image as UID 1000 with a read-only root filesystem and restricted Talos credentials. Kubernetes CronJob scheduling and Talos service-account Secret injection are not exercised.
- Docker Talos has no `reset` or `upgrade`, so the drill replaces the node instead of wiping it.

If a run fails, resources are left for inspection. `cleanup.py` removes only containers and the network named after that run.

## Offline contracts

Run `python3 packages/infrastructure/aws_kube_talos/tests/contracts.py` with OpenTofu 1.9+ and Talos 1.14 on PATH. This evaluates the module HCL for the CronJob and encryption policy, checks schedule and retention overrides, validates generated worker configuration, and runs five mocked AWS metadata architecture cases. It needs registry access for the AWS provider but no AWS credentials.

Talos 1.14 permits KubeProxyConfig only on controllers. Cilium's Flannel removal and kube-proxy disable configuration stays in the controller configuration; workers must not receive those control-plane documents. The worker test validates this with talosctl instead of asserting patch parity.

## Upgrade notes

The backup runtime is ghcr.io/siderolabs/talos-backup v0.1.0 pinned to its multi-platform digest. Snapshots remain uncompressed, without age encryption, and use bucket-default SSE-KMS. Object names now end in .snap. The checksum variable and custom Python uploader are removed. The default schedule is hourly UTC; etcd_backup_schedule overrides it. The retention default changes to 7 days; set etcd_backup_retention_days=30 explicitly to preserve the previous window.

Existing Talos inline manifests may retain the unused old source ConfigMap. After validating a new backup and reviewing its ownership, remove that obsolete ConfigMap separately. Updating the published source does not apply these changes to existing clusters.

Instance-type metadata lookups reject types that cannot run the module's ARM64 AMI, including controller overrides and worker fallback types. Plans now require ec2:DescribeInstanceTypes permission.

2026-11-17 validation used Talos 1.14.5 locally. The host's disk pressure blocked the harness CoreDNS readiness gate; the local API was reachable, so the backup/recovery test ran against that fixture. This is not a full local-cluster health qualification.
