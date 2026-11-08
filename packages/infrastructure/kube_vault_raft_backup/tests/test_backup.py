"""Exercise emitted backup behavior with synthetic Vault/S3 transports only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]

TRANSPORT = r'''
import hashlib,json,os,shutil,sys
from pathlib import Path
args=sys.argv[1:]; mode=Path(sys.argv[0]).name
root=Path(os.environ['MOCK_ROOT']); case=os.environ.get('MOCK_CASE','ok')
payload=sys.stdin.buffer.read() if mode=='curl' else b''
with (root/'calls.jsonl').open('a') as f:
 f.write(json.dumps({'tool':mode,'args':args,
  'token_stdin':b'SYNTHETIC_VAULT_TOKEN' in payload,
  'jwt_stdin':b'SYNTHETIC_VAULT_JWT' in payload,
  'static_aws_credentials_present':any(k in os.environ for k in ['AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_PROFILE']),
  'imds_disabled':os.environ.get('AWS_EC2_METADATA_DISABLED')=='true'})+'\n')
if mode=='curl':
 url=args[-1]
 if url.endswith('/login'):
  assert b'SYNTHETIC_VAULT_JWT' in payload
  print(json.dumps({'auth':{'client_token':'SYNTHETIC_VAULT_TOKEN'}}))
 elif url.endswith('/capabilities-self'):
  assert b'SYNTHETIC_VAULT_TOKEN' in payload
  print(json.dumps({'data':{'sys/storage/raft/snapshot':['read'],'secret/data/backup-capability-probe':['read'] if case=='kv-permitted' else ['deny']}}))
 elif url.endswith('/snapshot'):
  assert b'SYNTHETIC_VAULT_TOKEN' in payload
  Path(args[args.index('--output')+1]).write_bytes(b'seal-encrypted-synthetic-raft')
 elif url.endswith('/revoke-self'):
  assert b'SYNTHETIC_VAULT_TOKEN' in payload
 else: raise AssertionError('Unexpected Vault endpoint')
elif mode=='aws':
 op=args[1]; stored=root/'uploaded.snapshot'
 if op=='put-object':
  assert args[args.index('--if-none-match')+1]=='*'
  assert args[args.index('--server-side-encryption')+1]=='aws:kms'
  assert args[args.index('--ssekms-key-id')+1]==os.environ['BACKUP_KMS_KEY_ARN']
  assert args[args.index('--key')+1].startswith('vault/test-only/')
  if case=='upload-fails':sys.exit(42)
  shutil.copyfile(args[args.index('--body')+1],stored)
  print('{}')
 elif op=='head-object':
  print(json.dumps({'ServerSideEncryption':'aws:kms','SSEKMSKeyId':os.environ['BACKUP_KMS_KEY_ARN'],'Metadata':{'sha256':hashlib.sha256(stored.read_bytes()).hexdigest()}}))
 elif op=='get-object':
  Path(args[-1]).write_bytes(b'corrupted' if case=='corrupt-readback' else stored.read_bytes())
  print('{}')
 else:raise AssertionError('Unexpected AWS operation')
'''


class BackupRuntimeTests(unittest.TestCase):
    def execute(self, case="ok", limit="67108864"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work, binaries = root / "work", root / "bin"
            work.mkdir()
            binaries.mkdir()
            for name in ("aws", "curl"):
                file = binaries / name
                file.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(TRANSPORT))
                file.chmod(0o700)
            jwt = root / "vault-token"
            jwt.write_text("SYNTHETIC_VAULT_JWT")
            env = os.environ | {
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "MOCK_ROOT": str(root), "MOCK_CASE": case,
                "WORK_DIR": str(work), "VAULT_ADDR": "http://synthetic.invalid",
                "VAULT_ROLE": "backup-only", "VAULT_AUTH_MOUNT": "kubernetes",
                "VAULT_JWT_FILE": str(jwt), "AWS_ROLE_ARN": "synthetic-role",
                "AWS_WEB_IDENTITY_TOKEN_FILE": str(jwt),
                "BACKUP_BUCKET": "test-only", "BACKUP_PREFIX": "vault/test-only",
                "BACKUP_KMS_KEY_ARN": "arn:aws:kms:us-east-2:000000000000:key/test-only",
                "POD_UID": "test-pod", "MAX_SNAPSHOT_BYTES": limit,
                # These must be removed, even if inherited by accident.
                "AWS_PROFILE": "unwanted", "AWS_ACCESS_KEY_ID": "unwanted",
                "AWS_SECRET_ACCESS_KEY": "unwanted", "AWS_SESSION_TOKEN": "unwanted",
            }
            result = subprocess.run(["bash", str(ROOT / "backup.sh")],
                                    env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            self.assertFalse((work / "snapshot").exists())
            self.assertFalse((work / "readback").exists())
            for call in calls:
                self.assertNotIn("SYNTHETIC_VAULT_TOKEN", " ".join(call["args"]))
                self.assertNotIn("SYNTHETIC_VAULT_JWT", " ".join(call["args"]))
            self.assertNotIn("SYNTHETIC_VAULT_TOKEN", result.stdout + result.stderr)
            self.assertNotIn("SYNTHETIC_VAULT_JWT", result.stdout + result.stderr)
            self.assertTrue(any(c["args"][-1].endswith("revoke-self") for c in calls if c["tool"] == "curl"))
            return result, calls

    def test_verified_backup_uses_stdin_tokens_and_scoped_encryption(self):
        result, calls = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["status"], "verified")
        self.assertTrue(record["key"].endswith("-test-pod.snapshot"))
        self.assertEqual(len(record["sha256"]), 64)
        aws = [c for c in calls if c["tool"] == "aws"]
        self.assertEqual([c["args"][1] for c in aws], ["put-object", "head-object", "get-object"])
        self.assertTrue(all(c["imds_disabled"] and not c["static_aws_credentials_present"] for c in aws))

    def test_unexpected_kv_read_permission_blocks_snapshot_and_upload(self):
        result, calls = self.execute("kv-permitted")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c["tool"] == "aws" for c in calls))
        self.assertFalse(any(c["args"][-1].endswith("/snapshot") for c in calls if c["tool"] == "curl"))

    def test_corrupt_download_never_reports_verified(self):
        result, _calls = self.execute("corrupt-readback")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('"verified"', result.stdout)

    def test_size_limit_blocks_upload(self):
        result, calls = self.execute(limit="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c["tool"] == "aws" for c in calls))

    def test_failed_upload_never_reports_verified(self):
        result, calls = self.execute("upload-fails")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('"verified"', result.stdout)
        self.assertEqual(len([c for c in calls if c["tool"] == "aws"]), 1)


if __name__ == "__main__":
    unittest.main()
