#!/usr/bin/env python3
"""Provision an explicitly named local-only Talos and Floci environment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import uuid

from harness import load, run, wait_for

VERSION = "v1.14.5"
FLOCI_IMAGE = "floci/floci@sha256:e0b292df4dc9559b7b1bf4f51bdda4bb8e269276236438cd03cae661260ea8a9"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--port", type=int, default=14566)
    parser.add_argument("--subnet", default="10.87.241.0/24")
    args = parser.parse_args()
    directory = (args.directory or Path(tempfile.mkdtemp(prefix="homelab-etcd-smoke-"))).resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if (directory / "harness.json").exists():
        parser.error("Directory already owns an environment; clean it up first")
    os.chmod(directory, 0o700)
    name = "homelab-etcd-smoke-" + uuid.uuid4().hex[:8]
    import ipaddress
    node = str(ipaddress.ip_network(args.subnet)[2])
    state = dict(name=name, endpoint=f"http://127.0.0.1:{args.port}",
                 bucket=name, node=node, version=VERSION, subnet=args.subnet,
                 floci_image=FLOCI_IMAGE)
    (directory / "harness.json").write_text(json.dumps(state, indent=2) + "\n")
    print("Owned state directory:", directory, flush=True)
    try:
        target = directory / "talosctl"
        local = shutil.which("talosctl")
        if local and VERSION in subprocess.run([local, "version", "--client", "--short"],
                                               text=True, capture_output=True).stdout:
            shutil.copyfile(local, target)
        else:
            base = f"https://github.com/siderolabs/talos/releases/download/{VERSION}/"
            architecture = {"x86_64": "amd64", "aarch64": "arm64"}[os.uname().machine]
            filename = "talosctl-linux-" + architecture
            urllib.request.urlretrieve(base + filename, target)
            checksums = urllib.request.urlopen(base + "sha256sum.txt").read().decode()
            expected = next(line.split()[0] for line in checksums.splitlines()
                            if line.split()[-1].lstrip("*") == filename)
            if hashlib.sha256(target.read_bytes()).hexdigest() != expected:
                raise RuntimeError("talosctl release checksum mismatch")
        target.chmod(0o700)
        _, _, env = load(directory)
        run("docker", "run", "-d", "--name", name + "-floci", "-p",
            f"127.0.0.1:{args.port}:4566", "-e", "FLOCI_SERVICES_UI_ENABLED=false", FLOCI_IMAGE)
        wait_for(["aws", "s3api", "list-buckets"], env)
        run("aws", "s3api", "create-bucket", "--bucket", name, env=env)
        state["kms_key"] = run("aws", "kms", "create-key", "--description", name,
                               "--query", "KeyMetadata.Arn", "--output", "text", env=env, capture=True)
        (directory / "harness.json").write_text(json.dumps(state, indent=2) + "\n")
        patch = directory / "api-access.yaml"
        patch.write_text("apiVersion: v1alpha1\nkind: KubeTalosAPIAccessConfig\n"
                         "allowedRoles:\n  - os:etcd:backup\n"
                         "allowedKubernetesNamespaces:\n  - default\n")
        run(target, "cluster", "create", "docker", "--name", name, "--state", directory / "clusters",
            "--subnet", args.subnet, "--workers", "0", "--host-ip", "127.0.0.1",
            "--image", "ghcr.io/siderolabs/talos:" + VERSION,
            "--config-patch-controlplanes", "@" + str(patch),
            "--talosconfig-destination", directory / "talosconfig", env=env)
        print("READY:", directory, flush=True)
    except BaseException:
        print("Provisioning failed; owned resources remain for diagnosis. Run cleanup.py --directory", directory)
        raise


if __name__ == "__main__":
    main()
