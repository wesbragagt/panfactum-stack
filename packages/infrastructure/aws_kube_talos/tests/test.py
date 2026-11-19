#!/usr/bin/env python3
"""Back up etcd with the production script, lose the control plane, restore from S3."""
import argparse
import base64
import ipaddress
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

from harness import MODULE_DIR, load, run, talos, wait_for

# Run the exact image the CronJob pins
BACKUP_IMAGE = re.search(r'backup_image\s*=\s*"([^"]+)"', (MODULE_DIR / "backup.tf").read_text()).group(1)


def kubectl(env, kubeconfig, *args, capture=False):
    return run("kubectl", "--kubeconfig", kubeconfig, *args, env=env, capture=capture)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    directory, state, env = load(parser.parse_args().directory)
    name, node = state["name"], state["node"]
    kubeconfig = directory / "kubeconfig"
    marker = "before-" + uuid.uuid4().hex[:8]

    # The CronJob runs with a Talos service account limited to os:etcd:backup.
    backup_config = directory / "backup-talosconfig"
    run(*talos(directory, "config", "new", backup_config, "--roles", "os:etcd:backup"), env=env)
    denied = subprocess.run([directory / "talosctl", "--talosconfig", backup_config, "-e", node, "-n", node,
                             "get", "machineconfig"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if denied.returncode == 0:
        raise AssertionError("os:etcd:backup credentials can read the machine config")

    kubectl(env, kubeconfig, "create", "configmap", "dr-marker", "--from-literal=value=" + marker)
    prefix = f"etcd/{name}"
    run(directory / "talosctl", "--talosconfig", backup_config, "config", "endpoint", node, env=env)
    # Like the CronJob, send no SSE headers so the bucket default must apply the KMS key
    run("docker", "run", "--rm", "--network", "host", "--user", f"{os.getuid()}:{os.getgid()}",
        "-v", f"{backup_config}:/talosconfig:ro", "--tmpfs", "/work:mode=1777", "-w", "/work",
        "-e", "TALOSCONFIG=/talosconfig", "-e", "HOME=/work", "-e", "CLUSTER_NAME=" + name,
        "-e", "BUCKET=" + name, "-e", "S3_PREFIX=" + prefix, "-e", "DISABLE_ENCRYPTION=true",
        "-e", "CUSTOM_S3_ENDPOINT=" + state["endpoint"], "-e", "AWS_REGION=us-east-1",
        "-e", "AWS_ACCESS_KEY_ID=test", "-e", "AWS_SECRET_ACCESS_KEY=test", BACKUP_IMAGE, env=env)
    kubectl(env, kubeconfig, "create", "configmap", "dr-after-backup", "--from-literal=value=lost")

    key = run("aws", "s3api", "list-objects-v2", "--bucket", name, "--prefix", prefix + "/",
              "--query", "sort_by(Contents,&LastModified)[-1].Key", "--output", "text", env=env, capture=True)
    snapshot = directory / "restored.snapshot"
    run("aws", "s3", "cp", f"s3://{name}/{key}", snapshot, "--only-show-errors", env=env)

    # Keep only the secrets bundle, as recovery from the SOPS bundle would, then lose the control plane.
    container = name + "-controlplane-1"
    environment = run("docker", "inspect", container, "--format",
                      "{{range .Config.Env}}{{println .}}{{end}}", capture=True)
    userdata = next(line[len("USERDATA="):] for line in environment.splitlines() if line.startswith("USERDATA="))
    original = directory / "original-controlplane.yaml"
    original.write_bytes(base64.b64decode(userdata, validate=True))
    bundle = directory / "secrets-bundle.yaml"
    run(directory / "talosctl", "gen", "secrets", "--from-controlplane-config", original, "-o", bundle, "--force", env=env)
    original.unlink()
    run(directory / "talosctl", "cluster", "destroy", "--name", name, "--state", directory / "clusters", env=env)

    # A different address proves the restore does not depend on the lost node's identity
    replacement = str(ipaddress.ip_network(state["subnet"])[3])
    config = directory / "replacement-controlplane.yaml"
    run(directory / "talosctl", "gen", "config", name, f"https://{replacement}:6443", "--with-secrets", bundle,
        "--output-types", "controlplane", "-o", config, "--config-patch", "@" + str(directory / "api-access.yaml"),
        "--force", env=env)
    run("docker", "network", "create", "--subnet", state["subnet"], name)
    image = "ghcr.io/siderolabs/talos:" + state["version"]
    print("+ docker run", name + "-restore-1", "(USERDATA redacted)", flush=True)
    subprocess.run(["docker", "run", "-d", "--name", name + "-restore-1", "--hostname", name + "-restore-1",
                    "--network", name, "--ip", replacement, "--privileged", "--read-only",
                    "--security-opt", "seccomp=unconfined", "--security-opt", "label=disable",
                    "--tmpfs", "/tmp", "--tmpfs", "/run", "--tmpfs", "/system",
                    "--mount", "type=volume,dst=/var", "--mount", "type=volume,dst=/system/state",
                    "--mount", "type=volume,dst=/opt", "-e", "PLATFORM=container",
                    "-e", "USERDATA=" + base64.b64encode(config.read_bytes()).decode(), image],
                   check=True, stdout=subprocess.DEVNULL)
    node = replacement

    def talos_replacement(*args):
        return [str(directory / "talosctl"), "--talosconfig", str(directory / "talosconfig"), "-e", node, "-n", node, *args]

    # A fresh control plane waits in Preparing until it is bootstrapped.
    deadline = time.monotonic() + 300
    while "Preparing" not in subprocess.run(talos_replacement("service", "etcd"), env=env,
                                            text=True, capture_output=True).stdout:
        if time.monotonic() > deadline:
            raise RuntimeError("etcd never reached Preparing on the replacement node")
        time.sleep(5)
    run(*talos_replacement("bootstrap", "--recover-from", snapshot), env=env)

    restored = directory / "restore-kubeconfig"
    run(*talos_replacement("kubeconfig", restored, "--force"), env=env)
    wait_for(["kubectl", "--kubeconfig", restored, "get", "configmap", "dr-marker"], env, seconds=300)
    value = kubectl(env, restored, "get", "configmap", "dr-marker", "-o", "jsonpath={.data.value}", capture=True)
    if value != marker:
        raise AssertionError(f"Restored marker {value!r}, expected {marker!r}")
    # A failed kubectl call must fail the test, not count as "absent"
    after = kubectl(env, restored, "get", "configmap", "dr-after-backup", "--ignore-not-found", "-o", "name", capture=True)
    if after:
        raise AssertionError("Object created after the backup survived the restore")
    print(f"PASS: restored {marker!r} from s3://{name}/{key}", flush=True)


if __name__ == "__main__":
    main()
