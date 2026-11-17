import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "oidc-jwks.py"
spec = importlib.util.spec_from_file_location("oidc_jwks", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OIDCJWKSTest(unittest.TestCase):
    def test_public_key_matches_signing_key_and_kubernetes_key_id(self):
        private = subprocess.check_output(["openssl", "genrsa", "2048"], stderr=subprocess.DEVNULL)
        public = subprocess.check_output(["openssl", "pkey", "-pubout", "-outform", "DER"], input=private)
        modulus = subprocess.check_output(["openssl", "rsa", "-modulus", "-noout"], input=private)
        result = module.jwks(base64.b64encode(private))
        key = result["keys"][0]
        self.assertEqual(set(key), {"use", "kty", "kid", "alg", "n", "e"})
        self.assertEqual(key["kid"], module.b64url(hashlib.sha256(public).digest()))
        self.assertEqual(key["n"], module.b64url(bytes.fromhex(modulus.decode().strip().split("=")[1])))
        self.assertEqual(key["e"], "AQAB")
        completed = subprocess.run(["python3", str(SCRIPT)], input=json.dumps({"private_key": base64.b64encode(private).decode()}), text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(json.loads(completed.stdout)["jwks_json"]), result)
        self.assertNotIn("PRIVATE", completed.stdout + completed.stderr)

    def test_invalid_key_does_not_echo_input(self):
        completed = subprocess.run(["python3", str(SCRIPT)], input=json.dumps({"private_key": "secret-invalid-input"}), text=True, capture_output=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertNotIn("secret-invalid-input", completed.stdout + completed.stderr)


if __name__ == "__main__":
    unittest.main()
