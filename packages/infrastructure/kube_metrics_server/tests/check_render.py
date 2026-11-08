"""Validate a rendered Helm certificate-mode manifest, including its trust bundle.

Usage: python check_render.py manifest.yaml
Capture manifests privately: they contain a TLS private key. Never print them.
"""
import base64
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml


def check(path):
    docs = [d for d in yaml.safe_load_all(Path(path).read_text()) if d]
    deployment = next(d for d in docs if d["kind"] == "Deployment")
    pod = deployment["spec"]["template"]["spec"]
    container = next(c for c in pod["containers"] if c["name"] == "metrics-server")
    api = next(d for d in docs if d["kind"] == "APIService")
    assert api["spec"].get("insecureSkipTLSVerify", False) is False
    secret = next(d for d in docs if d["kind"] == "Secret" and "tls.crt" in d.get("data", {}))
    assert api["spec"]["caBundle"] == secret["data"]["tls.crt"]
    assert not any(d["kind"] == "Certificate" for d in docs)
    assert "--tls-cert-file=/tmp/tls-certs/tls.crt" in container["args"]
    assert "--tls-private-key-file=/tmp/tls-certs/tls.key" in container["args"]
    mount = next(m for m in container["volumeMounts"] if m["mountPath"] == "/tmp/tls-certs")
    volume = next(v for v in pod["volumes"] if v["name"] == mount["name"])
    assert volume["secret"]["secretName"] == secret["metadata"]["name"]
    assert len({v["name"] for v in pod["volumes"]}) == len(pod["volumes"])
    service = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == api["spec"]["service"]["name"])
    assert all(deployment["spec"]["template"]["metadata"]["labels"].get(k) == v for k, v in service["spec"]["selector"].items())
    dns_name = f'{service["metadata"]["name"]}.{service["metadata"]["namespace"]}.svc'
    with tempfile.TemporaryDirectory() as tmp:
        cert = Path(tmp) / "cert.pem"
        cert.write_bytes(base64.b64decode(secret["data"]["tls.crt"]))
        result = subprocess.run(["openssl", "verify", "-CAfile", str(cert), "-verify_hostname", dns_name, str(cert)], capture_output=True)
        assert result.returncode == 0, "Serving certificate must verify for the APIService DNS name"
    print("Helm TLS certificate, trust bundle, mounts, and service routing checks passed")


if __name__ == "__main__":
    check(sys.argv[1])
