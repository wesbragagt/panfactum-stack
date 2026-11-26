"""Check the API and CCM before the bootstrap workflow starts Cilium."""

from datetime import datetime, timedelta, timezone
import json
import os
import subprocess
import sys
import time


def check_api(kubectl):
    kubectl("get", "--raw=/readyz")
    kubectl("get", "namespace", "kube-system")


def check_node(kubectl, private_ip, provider_id):
    lease = json.loads(kubectl("get", "lease", "cloud-controller-manager", "-n", "kube-system", "-o", "json"))["spec"]
    if not lease.get("holderIdentity") or not lease.get("renewTime"):
        raise ValueError("The CCM lease has no leader")
    expires = datetime.fromisoformat(lease["renewTime"].replace("Z", "+00:00")) + timedelta(seconds=lease["leaseDurationSeconds"])
    if expires <= datetime.now(timezone.utc):
        raise ValueError("The CCM leader lease expired")

    nodes = json.loads(kubectl("get", "nodes", "-l", "node-role.kubernetes.io/control-plane", "-o", "json"))["items"]
    matches = [
        node for node in nodes
        if any(address["type"] == "InternalIP" and address["address"] == private_ip
               for address in node.get("status", {}).get("addresses", []))
    ]
    if len(matches) != 1:
        raise ValueError(f"Expected one controller at {private_ip}, found {len(matches)}")
    spec = matches[0]["spec"]
    if spec.get("providerID") != provider_id:
        raise ValueError(f"Controller at {private_ip} reports {spec.get('providerID')}, expected {provider_id}")
    if any(taint["key"] == "node.cloudprovider.kubernetes.io/uninitialized" for taint in spec.get("taints", [])):
        raise ValueError(f"Controller at {private_ip} still has the cloud uninitialized taint")


def main(mode):
    kubeconfig = os.environ.pop("KUBECONFIG_RAW")
    command = ["kubectl", "--kubeconfig=/dev/stdin", "--request-timeout=10s",
               f"--server={os.environ['KUBE_API_SERVER']}"]
    if tls_name := os.environ["KUBE_TLS_SERVER_NAME"]:
        command.append(f"--tls-server-name={tls_name}")

    def kubectl(*args):
        return subprocess.run(
            [*command, *args], input=kubeconfig, text=True, capture_output=True, timeout=12, check=True,
        ).stdout

    deadline = time.monotonic() + 300
    while True:
        try:
            if mode == "api":
                check_api(kubectl)
            else:
                check_node(kubectl, os.environ["CONTROLLER_IP"], os.environ["PROVIDER_ID"])
            return 0
        except subprocess.CalledProcessError as exc:
            problem = exc.stderr.strip() or "kubectl request failed"
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            problem = str(exc)
        if time.monotonic() >= deadline:
            print(f"CCM {mode} check: {problem}", file=sys.stderr)
            return 1
        time.sleep(3)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
