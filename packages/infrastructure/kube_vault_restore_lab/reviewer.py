#!/usr/bin/env python3
"""Lab-only TokenReview bridge. No generic API proxy and no request-body logs."""
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import ssl
import urllib.error
import urllib.request

AUDIENCE = "migration-lab"
MAX_BODY = 16384


class RefuseRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, newurl):
        return None


def validate_review(value):
    if (not isinstance(value, dict) or
            "spec" not in value or
            not set(value).issubset({"apiVersion", "kind", "spec", "metadata", "status"}) or
            value.get("metadata", {}) not in ({}, {"creationTimestamp": None}) or
            value.get("status", {}) not in ({}, {"user": {}})):
        return False
    spec = value.get("spec")
    return (value.get("apiVersion", "authentication.k8s.io/v1") == "authentication.k8s.io/v1" and
            value.get("kind", "TokenReview") == "TokenReview" and isinstance(spec, dict) and
            set(spec) == {"token", "audiences"} and spec["audiences"] == [AUDIENCE] and
            isinstance(spec["token"], str) and 0 < len(spec["token"]) <= 8192 and
            re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", spec["token"]) is not None)


def filtered_review(value, namespace, accounts):
    status = value.get("status", {}) if isinstance(value, dict) else {}
    user = status.get("user", {})
    prefix = "system:serviceaccount:" + namespace + ":"
    username = user.get("username", "")
    allowed = (status.get("authenticated") is True and
               status.get("audiences") == [AUDIENCE] and
               username.startswith(prefix) and username[len(prefix):] in accounts and
               isinstance(user.get("uid"), str) and bool(user["uid"]))
    result = {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview",
              "status": {"authenticated": False}}
    if allowed:
        # Do not reflect TokenReview.spec.token, extra attributes or raw errors.
        result["status"] = {"authenticated": True, "audiences": [AUDIENCE],
                            "user": {"username": username, "uid": user["uid"],
                                     "groups": [g for g in user.get("groups", []) if g in
                                                ["system:authenticated", "system:serviceaccounts",
                                                 "system:serviceaccounts:" + namespace]]}}
    return result


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "LabTokenReview"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def reply(self, code, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"status": "ok"})
        else:
            self.reply(404, {"error": "unsupported endpoint"})

    def do_POST(self):
        if self.path != "/apis/authentication.k8s.io/v1/tokenreviews":
            self.reply(404, {"error": "unsupported endpoint"})
            return
        authorization = self.headers.get("Authorization", "")
        if not hmac.compare_digest(authorization.encode(), ("Bearer " + self.server.proxy_token).encode()):
            self.reply(401, {"error": "unauthorized"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= MAX_BODY or self.headers.get("Transfer-Encoding"):
                self.reply(400, {"error": "invalid payload"})
                return
            data = self.rfile.read(size)
            if len(data) != size:
                raise ValueError("short payload")
            value = json.loads(data)
            if not validate_review(value):
                self.reply(400, {"error": "invalid review"})
                return
            # Vault 1.14.7 marshals an untyped Go TokenReview including empty
            # metadata/status. Forward only this canonical, typed request.
            result = self.server.review({"apiVersion": "authentication.k8s.io/v1",
                                         "kind": "TokenReview", "spec": value["spec"]})
            self.reply(200, filtered_review(result, self.server.namespace, self.server.accounts))
        except Exception:
            self.reply(503, {"error": "verification unavailable"})

    def log_message(self, *args):
        pass

    def log_error(self, *args):
        pass


def main():
    namespace = os.environ["LAB_NAMESPACE"]
    if not namespace.startswith("vault-migration-"):
        raise ValueError("dedicated lab namespace required")
    accounts = set(os.environ.get("LAB_ACCOUNTS", "migration-test-vso,migration-test-client").split(","))
    if not accounts or any(not x.startswith("migration-test-") for x in accounts):
        raise ValueError("dedicated lab service accounts required")
    proxy_token = Path("/authorization/token").read_text().strip()
    if len(proxy_token) < 32 or any(x.isspace() for x in proxy_token):
        raise ValueError("valid private authorization required")
    context = ssl.create_default_context(cafile="/identity/ca.crt")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), RefuseRedirect(),
                                        urllib.request.HTTPSHandler(context=context))

    def review(value):
        token = Path("/identity/token").read_text().strip()
        request = urllib.request.Request(
            "https://kubernetes.default.svc:443/apis/authentication.k8s.io/v1/tokenreviews",
            data=json.dumps(value).encode(), method="POST",
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with opener.open(request, timeout=5) as response:
            data = response.read(65537)
            if len(data) > 65536:
                raise ValueError("oversize verification response")
            return json.loads(data)

    server = HTTPServer(("0.0.0.0", 8080), Handler)
    server.proxy_token = proxy_token
    server.namespace = namespace
    server.accounts = accounts
    server.review = review
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("Lab reviewer startup failed; diagnostics suppressed") from None
