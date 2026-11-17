#!/usr/bin/env python3
"""Back up etcd with the production container, lose the control plane, restore from S3."""
import argparse
import base64
import re
from pathlib import Path
import subprocess
import time
import uuid

from harness import MODULE_DIR, load, run, talos, wait_for

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
    backup_config = directory / ("backup-talosconfig-" + uuid.uuid4().hex[:8])
    run(*talos(directory, "config", "new", backup_config, "--roles", "os:etcd:backup"), env=env)
    denied = subprocess.run([directory / "talosctl", "--talosconfig", backup_config, "-e", node, "-n", node,
                             "get", "machineconfig"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if denied.returncode == 0:
        raise AssertionError("os:etcd:backup credentials can read the machine config")

    kubectl(env, kubeconfig, "delete", "configmap", "dr-marker", "dr-after-backup", "--ignore-not-found")
    kubectl(env, kubeconfig, "create", "configmap", "dr-marker", "--from-literal=value=" + marker)
    prefix = f"etcd/{name}"
    run(directory / "talosctl", "--talosconfig", backup_config, "config", "endpoint", node, env=env)
    run(directory / "talosctl", "--talosconfig", backup_config, "config", "node", node, env=env)
    run("docker", "run", "--rm", "--network", "host", "--read-only", "--user", "1000:1000",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
        "--tmpfs", "/tmp:rw,uid=1000,gid=1000,size=3g", "--workdir", "/tmp",
        "--mount", f"type=bind,src={backup_config},dst=/var/run/secrets/talos.dev/config,readonly",
        "-e", "TALOSCONFIG=/var/run/secrets/talos.dev/config",
        "-e", "AWS_ACCESS_KEY_ID=test", "-e", "AWS_SECRET_ACCESS_KEY=test", "-e", "AWS_REGION=us-east-1",
        "-e", "CUSTOM_S3_ENDPOINT=" + state["endpoint"], "-e", "BUCKET=" + name,
        "-e", "S3_PREFIX=" + prefix, "-e", "CLUSTER_NAME=" + name,
        "-e", "DISABLE_ENCRYPTION=true", "-e", "ENABLE_COMPRESSION=false", BACKUP_IMAGE, env=env)
    kubectl(env, kubeconfig, "create", "configmap", "dr-after-backup", "--from-literal=value=lost")

    key = run("aws", "s3api", "list-objects-v2", "--bucket", name, "--prefix", prefix + "/",
              "--query", "sort_by(Contents,&LastModified)[-1].Key", "--output", "text", env=env, capture=True)
    # Floci does not reflect bucket-default encryption in object metadata.
    encryption = run("aws", "s3api", "get-bucket-encryption", "--bucket", name, "--query",
                     "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.[SSEAlgorithm,KMSMasterKeyID]",
                     "--output", "text", env=env, capture=True).split()
    if encryption != ["aws:kms", state["kms_key"]]:
        raise AssertionError(f"Bucket not configured for the backup KMS key: {encryption}")
    snapshot = directory / "restored.snapshot"
    run("aws", "s3", "cp", f"s3://{name}/{key}", snapshot, "--only-show-errors", env=env)

    # Preserve the machine config (which holds the cluster secrets), then lose the control plane.
    container = name + "-controlplane-1"
    environment = run("docker", "inspect", container, "--format",
                      "{{range .Config.Env}}{{println .}}{{end}}", capture=True)
    userdata = next(line[len("USERDATA="):] for line in environment.splitlines() if line.startswith("USERDATA="))
    base64.b64decode(userdata, validate=True)
    run(directory / "talosctl", "cluster", "destroy", "--name", name, "--state", directory / "clusters", env=env)

    run("docker", "network", "create", "--subnet", state["subnet"], name)
    image = "ghcr.io/siderolabs/talos:" + state["version"]
    print("+ docker run", name + "-restore-1", "(USERDATA redacted)", flush=True)
    subprocess.run(["docker", "run", "-d", "--name", name + "-restore-1", "--hostname", container,
                    "--network", name, "--ip", node, "--privileged", "--read-only",
                    "--security-opt", "seccomp=unconfined", "--security-opt", "label=disable",
                    "--tmpfs", "/tmp", "--tmpfs", "/run", "--tmpfs", "/system",
                    "--mount", "type=volume,dst=/var", "--mount", "type=volume,dst=/system/state",
                    "--mount", "type=volume,dst=/opt", "-e", "PLATFORM=container",
                    "-e", "USERDATA=" + userdata, image], check=True, stdout=subprocess.DEVNULL)

    # A fresh control plane waits in Preparing until it is bootstrapped.
    deadline = time.monotonic() + 300
    while "Preparing" not in subprocess.run(talos(directory, "-e", node, "service", "etcd"), env=env,
                                            text=True, capture_output=True).stdout:
        if time.monotonic() > deadline:
            raise RuntimeError("etcd never reached Preparing on the replacement node")
        time.sleep(5)
    run(*talos(directory, "-e", node, "bootstrap", "--recover-from", snapshot), env=env)

    restored = directory / "restore-kubeconfig"
    run(*talos(directory, "-e", node, "kubeconfig", restored, "--force"), env=env)
    wait_for(["kubectl", "--kubeconfig", restored, "get", "configmap", "dr-marker"], env, seconds=300)
    value = kubectl(env, restored, "get", "configmap", "dr-marker", "-o", "jsonpath={.data.value}", capture=True)
    if value != marker:
        raise AssertionError(f"Restored marker {value!r}, expected {marker!r}")
    after = subprocess.run(["kubectl", "--kubeconfig", restored, "get", "configmap", "dr-after-backup"],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if after.returncode == 0:
        raise AssertionError("Object created after the backup survived the restore")
    print(f"PASS: restored {marker!r} from s3://{name}/{key}", flush=True)


if __name__ == "__main__":
    main()
