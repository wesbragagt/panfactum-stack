#!/usr/bin/env python3
"""Generate the Talos secrets bundle once and write it SOPS-encrypted.

The plaintext only ever exists in a 0700 temp directory that is removed on exit.
The bundle is `talosctl gen secrets` output plus a `clientconfig` block (the admin
credentials Terraform uses for the Talos API), so `talosctl gen config
--with-secrets` accepts the decrypted file unchanged.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path,
                        help="Encrypted output file, e.g. environments/<env>/<region>/aws_kube_talos/talos-secrets.yaml")
    args = parser.parse_args()
    target = args.target.resolve()

    # Regenerating replaces the whole cluster PKI, so never overwrite silently.
    if target.exists():
        sys.exit(f"{target} already exists; delete it deliberately if you really want a new cluster PKI")
    for tool in ("talosctl", "sops"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found in PATH")

    work = Path(tempfile.mkdtemp(prefix="talos-secrets-"))
    try:
        os.chmod(work, 0o700)
        secrets = work / "secrets.yaml"
        subprocess.run(["talosctl", "gen", "secrets", "--output-file", str(secrets)],
                       check=True, stdout=subprocess.DEVNULL)

        # The cluster name and endpoint only label the talosconfig; the credentials come from the secrets.
        subprocess.run(["talosctl", "gen", "config", "bundle", "https://localhost:6443",
                        "--with-secrets", str(secrets), "--output-types", "talosconfig",
                        "--output", str(work / "talosconfig")],
                       check=True, stdout=subprocess.DEVNULL)
        config = (work / "talosconfig").read_text()
        client = {key: re.search(rf"^\s+{key}: (\S+)$", config, re.MULTILINE).group(1)
                  for key in ("ca", "crt", "key")}
        with secrets.open("a") as file:
            file.write("clientconfig:\n" + "".join(f"  {key}: {value}\n" for key, value in client.items()))

        encrypted = work / "encrypted.yaml"
        with encrypted.open("w") as file:
            # --filename-override makes sops pick the creation rule for the final path, not the temp path.
            subprocess.run(["sops", "encrypt", "--filename-override", str(target),
                            "--input-type", "yaml", "--output-type", "yaml", str(secrets)],
                           check=True, stdout=file)
        shutil.copyfile(encrypted, target)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"Wrote {target}")


if __name__ == "__main__":
    main()
