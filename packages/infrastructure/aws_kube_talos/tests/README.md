# Talos etcd backup test

Proves that the pinned [talos-backup](https://github.com/siderolabs/talos-backup) image in `backup.tf` produces a snapshot that can rebuild a lost control plane. Everything runs locally: a Talos cluster in Docker and [Floci](https://github.com/floci-io/floci) as the AWS S3 and KMS emulator. No real AWS account is touched.

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
2. Writes ConfigMap `dr-marker`, runs the talos-backup image with no SSE headers, then writes ConfigMap `dr-after-backup`.
3. Downloads the newest snapshot object.
4. Saves the node's machine config, destroys the cluster, and starts a replacement node with the same config.
5. Runs `talosctl bootstrap --recover-from` with the downloaded snapshot.
6. Passes only if `dr-marker` is restored with its value and `dr-after-backup` is absent.

## Limits

- Floci stores bucket-default encryption but does not apply it to uploads, so SSE-KMS is checked only on real AWS. Floci does not enforce IAM and KMS policies either. The bucket policy and IAM permissions in `backup.tf` are only validated by a real AWS apply.
- The script runs on the host. The CronJob in `backup.tf` and its Talos service account mount are not exercised here; the test uses a talosconfig with the same `os:etcd:backup` role.
- Docker Talos has no `reset` or `upgrade`, so the drill replaces the node instead of wiping it.

If a run fails, resources are left for inspection. `cleanup.py` removes only containers and the network named after that run.
