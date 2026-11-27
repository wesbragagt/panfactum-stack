"""Set a controller Node's AWS provider ID before CCM starts. A matching ID is left unchanged."""

import json
import os
import subprocess
import sys
import time


def reconcile(kubectl, private_ip, provider_id, *, attempts=30):
    for attempt in range(attempts):
        try:
            nodes = json.loads(kubectl("get", "nodes", "-o", "json"))["items"]
            matches = [
                node for node in nodes
                if any(address["type"] == "InternalIP" and address["address"] == private_ip
                       for address in node.get("status", {}).get("addresses", []))
            ]
            if len(matches) > 1:
                raise ValueError(f"More than one Node reports InternalIP {private_ip}")
            if not matches:
                problem = f"No Node reports InternalIP {private_ip}"
            else:
                node = matches[0]
                metadata = node["metadata"]
                if "node-role.kubernetes.io/control-plane" not in metadata.get("labels", {}):
                    problem = f"Node {metadata['name']} at {private_ip} has no control-plane label"
                else:
                    assign(kubectl, nodes, node, provider_id)
                    return
        except subprocess.CalledProcessError as exc:
            problem = exc.stderr.strip() or "kubectl request failed"
        except subprocess.TimeoutExpired:
            problem = "kubectl request timed out"
        if attempt + 1 < attempts:
            time.sleep(2)
    raise ValueError(problem)


def assign(kubectl, nodes, node, provider_id):
    metadata = node["metadata"]
    name = metadata["name"]
    for other in nodes:
        if other is not node and other.get("spec", {}).get("providerID") == provider_id:
            raise ValueError(f"Node {other['metadata']['name']} already has {provider_id}")

    current = node.get("spec", {}).get("providerID")
    if current == provider_id:
        return
    if current:
        raise ValueError(f"Node {name} has {current}, expected {provider_id}. "
                         "For a replaced controller, check the dead-controller runbook.")

    # NOTE: The API must reject the patch if the Node is replaced or changed after the list.
    operations = [
        {"op": "test", "path": "/metadata/uid", "value": metadata["uid"]},
        {"op": "test", "path": "/metadata/resourceVersion", "value": metadata["resourceVersion"]},
        {"op": "add", "path": "/spec/providerID", "value": provider_id},
    ]
    kubectl("patch", "node", name, "--type=json", f"--patch={json.dumps(operations)}")


def kubectl_command():
    # NOTE: These match the generated Kubernetes provider: KUBE_CONFIG_PATH plus pf_metadata context and server.
    command = ["kubectl", "--request-timeout=10s"]
    for flag, variable in (
        ("--kubeconfig", "KUBE_CONFIG_PATH"),
        ("--context", "PF_KUBE_CONFIG_CONTEXT"),
        ("--server", "PF_KUBE_API_SERVER"),
    ):
        if value := os.environ.get(variable):
            command.append(f"{flag}={value}")
    return command


def main():
    identity = json.loads(os.environ["CONTROLLER_IDENTITY"])
    command = kubectl_command()

    def kubectl(*args):
        return subprocess.run(
            [*command, *args], text=True, capture_output=True, timeout=30, check=True,
        ).stdout

    try:
        reconcile(kubectl, **identity)
    except (OSError, ValueError) as exc:
        print(f"controller provider ID: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
