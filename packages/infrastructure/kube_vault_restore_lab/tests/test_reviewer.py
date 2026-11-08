"""Exercise the real HTTP boundary without a Kubernetes credential or API."""
import importlib.util
import json
from pathlib import Path
import threading
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location("reviewer", Path(__file__).parents[1] / "reviewer.py")
reviewer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reviewer)


class Boundary(unittest.TestCase):
    def setUp(self):
        self.called = []
        self.server = reviewer.HTTPServer(("127.0.0.1", 0), reviewer.Handler)
        self.server.proxy_token = "synthetic-authorization-0123456789"
        self.server.namespace = "vault-migration-fixture"
        self.server.accounts = {"migration-test-client"}
        self.server.review = self.review
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.address = "http://127.0.0.1:" + str(self.server.server_port)
        self.payload = {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview",
                        "metadata": {"creationTimestamp": None},
                        "spec": {"token": "synthetic.jwt.value", "audiences": ["migration-lab"]}}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def review(self, value):
        self.called.append(value)
        return {"spec": value["spec"], "status": {"authenticated": True,
                "audiences": ["migration-lab"], "user": {
                    "username": "system:serviceaccount:vault-migration-fixture:migration-test-client",
                    "uid": "synthetic-uid", "extra": {"sensitive": "synthetic-only"},
                    "groups": ["system:authenticated", "unrelated-group"]}}}

    def request(self, path="/apis/authentication.k8s.io/v1/tokenreviews", payload=None,
                authorization=True, method="POST", headers=None):
        headers = dict(headers or {})
        if authorization:
            headers["Authorization"] = "Bearer " + self.server.proxy_token
        data = json.dumps(self.payload if payload is None else payload).encode() if method == "POST" else None
        request = urllib.request.Request(self.address + path, data=data, method=method, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=2)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.code, response.read()

    def test_exact_review_succeeds_without_reflecting_token_or_extra(self):
        code, body = self.request()
        self.assertEqual(code, 200)
        value = json.loads(body)
        self.assertTrue(value["status"]["authenticated"])
        self.assertEqual(len(self.called), 1)
        self.assertNotIn(b"synthetic.jwt.value", body)
        self.assertNotIn(b"sensitive", body)
        self.assertEqual(value["status"]["user"]["groups"], ["system:authenticated"])

    def test_arbitrary_api_and_missing_auth_never_forwarded(self):
        self.assertEqual(self.request(path="/api/v1/secrets")[0], 404)
        self.assertEqual(self.request(authorization=False)[0], 401)
        self.assertEqual(self.called, [])

    def test_original_vault_untyped_request_is_canonicalized(self):
        value = {"metadata": {"creationTimestamp": None}, "spec": self.payload["spec"], "status": {"user": {}}}
        code, body = self.request(payload=value)
        self.assertEqual(code, 200)
        self.assertTrue(json.loads(body)["status"]["authenticated"])
        self.assertEqual(set(self.called[0]), {"apiVersion", "kind", "spec"})

    def test_wrong_audience_and_arbitrary_fields_never_forwarded(self):
        self.payload["spec"]["audiences"] = ["production"]
        self.assertEqual(self.request()[0], 400)
        self.payload["spec"]["audiences"] = ["migration-lab"]
        self.payload["spec"]["resource"] = "secrets"
        self.assertEqual(self.request()[0], 400)
        self.assertEqual(self.called, [])

    def test_metadata_and_payload_type_are_validated(self):
        self.assertEqual(self.request(payload=[])[0], 400)
        self.payload["metadata"] = {"name": "unexpected"}
        self.assertEqual(self.request()[0], 400)
        self.assertEqual(self.called, [])

    def test_unbounded_token_is_rejected(self):
        self.payload["spec"]["token"] = "a" * 8193
        self.assertEqual(self.request()[0], 400)
        self.assertEqual(self.called, [])

    def test_other_namespace_and_account_fail_closed(self):
        for username in ["system:serviceaccount:production:migration-test-client",
                         "system:serviceaccount:vault-migration-fixture:production-user"]:
            self.server.review = lambda value: {"status": {"authenticated": True,
                    "audiences": ["migration-lab"], "user": {"username": username, "uid": "synthetic"}}}
            code, body = self.request()
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)["status"], {"authenticated": False})

    def test_upstream_failure_does_not_echo_exception(self):
        def failure(value):
            raise RuntimeError("synthetic-sensitive-upstream-detail")
        self.server.review = failure
        code, body = self.request()
        self.assertEqual(code, 503)
        self.assertNotIn(b"sensitive", body)

    def test_only_health_endpoint_has_unauthenticated_read(self):
        self.assertEqual(self.request(path="/healthz", method="GET", authorization=False)[0], 200)
        self.assertEqual(self.request(path="/api/v1/secrets", method="GET", authorization=False)[0], 404)
        self.assertEqual(self.called, [])


if __name__ == "__main__":
    unittest.main()
