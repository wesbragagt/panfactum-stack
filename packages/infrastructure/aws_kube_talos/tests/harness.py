"""Shared helpers for the disposable Talos/Floci integration test."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import time


MODULE_DIR = Path(__file__).resolve().parents[1]


def run(*args, env=None, capture=False):
    print("+", shlex.join(str(arg) for arg in args), flush=True)
    result = subprocess.run([str(arg) for arg in args], env=env, check=True,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def load(directory):
    directory = Path(directory).resolve()
    state = json.loads((directory / "harness.json").read_text())
    if not state["name"].startswith("homelab-etcd-smoke-"):
        raise ValueError("Refusing resources outside the harness naming convention")
    env = os.environ.copy()
    # Never inherit real AWS credentials, profiles, or user cluster selection.
    for key in list(env):
        if key.startswith("AWS_") or key in ("KUBECONFIG", "TALOSCONFIG"):
            env.pop(key)
    env.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test",
               AWS_REGION="us-east-1", AWS_DEFAULT_REGION="us-east-1",
               AWS_EC2_METADATA_DISABLED="true", AWS_CONFIG_FILE="/dev/null",
               AWS_SHARED_CREDENTIALS_FILE="/dev/null", AWS_PAGER="",
               AWS_ENDPOINT_URL=state["endpoint"],
               TALOSCONFIG=str(directory / "talosconfig"),
               KUBECONFIG=str(directory / "kubeconfig"),
               PATH=str(directory) + os.pathsep + env["PATH"])
    return directory, state, env


def wait_for(command, env, seconds=180):
    deadline = time.monotonic() + seconds
    while True:
        result = subprocess.run([str(a) for a in command], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode == 0:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("Timed out waiting for " + shlex.join(command))
        time.sleep(2)


def talos(directory, *args):
    node = json.loads((directory / "harness.json").read_text())["node"]
    return [str(directory / "talosctl"), "--talosconfig", str(directory / "talosconfig"),
            "--nodes", node, *args]
