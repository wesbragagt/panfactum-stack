#!/usr/bin/env python3
"""Take a Talos etcd snapshot and upload it to an SSE-KMS-encrypted S3 object."""

import datetime
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def main():
    talosconfig = os.environ["TALOSCONFIG"]
    endpoint = os.environ["TALOS_ENDPOINT"]
    node = os.environ["TALOS_NODE"]
    bucket = os.environ["BACKUP_BUCKET"]
    prefix = os.environ["BACKUP_PREFIX"].strip("/")
    kms_key = os.environ["BACKUP_KMS_KEY_ID"]
    region = os.environ["AWS_REGION"]
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    key = f"{prefix}/{timestamp}-{uuid.uuid4().hex}.snapshot"
    destination = f"s3://{bucket}/{key}"

    with tempfile.TemporaryDirectory(prefix="etcd-backup-") as directory:
        snapshot = Path(directory) / "etcd.snapshot"
        subprocess.run(
            ["talosctl", "--talosconfig", talosconfig, "--endpoints", endpoint,
             "--nodes", node, "etcd", "snapshot", str(snapshot)],
            check=True,
        )
        if snapshot.stat().st_size == 0:
            raise RuntimeError("Talos returned an empty etcd snapshot")
        upload = ["aws", "--region", region]
        if os.environ.get("AWS_ENDPOINT_URL"):
            upload.extend(["--endpoint-url", os.environ["AWS_ENDPOINT_URL"]])
        upload.extend([
            "s3", "cp", str(snapshot), destination, "--sse", "aws:kms",
            "--sse-kms-key-id", kms_key, "--only-show-errors",
        ])
        subprocess.run(upload, check=True)
        print(f"Uploaded {snapshot.stat().st_size} bytes to {destination}", flush=True)


if __name__ == "__main__":
    main()
