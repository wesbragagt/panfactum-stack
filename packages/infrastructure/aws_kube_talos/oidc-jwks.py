#!/usr/bin/env python3
"""Derive Kubernetes-compatible public RSA JWKS without writing private keys to disk."""
import base64
import hashlib
import json
import subprocess
import sys


def b64url(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def der_value(data, offset=0):
    tag, length = data[offset:offset + 2]
    offset += 2
    if length & 128:
        size = length & 127
        length = int.from_bytes(data[offset:offset + size], "big")
        offset += size
    return tag, data[offset:offset + length], offset + length


def jwks(private_key):
    result = subprocess.run(
        ["openssl", "pkey", "-pubout", "-outform", "DER"],
        input=base64.b64decode(private_key), capture_output=True,
    )
    if result.returncode:
        raise ValueError("Cannot derive the service-account public key")
    public_der = result.stdout
    _, sequence, _ = der_value(public_der)
    _, _, offset = der_value(sequence)
    tag, bits, _ = der_value(sequence, offset)
    if tag != 3 or bits[0] != 0:
        raise ValueError("Expected a public-key bit string")
    _, rsa, _ = der_value(bits[1:])
    _, modulus, offset = der_value(rsa)
    tag, exponent, _ = der_value(rsa, offset)
    if tag != 2:
        raise ValueError("Expected an RSA service-account signing key")
    # Kubernetes hashes the DER SubjectPublicKeyInfo to identify signing keys.
    return {"keys": [{"use": "sig", "kty": "RSA", "kid": b64url(hashlib.sha256(public_der).digest()),
                      "alg": "RS256", "n": b64url(modulus.lstrip(b"\0")),
                      "e": b64url(exponent.lstrip(b"\0"))}]}


if __name__ == "__main__":
    try:
        query = json.load(sys.stdin)
        print(json.dumps({"jwks_json": json.dumps(jwks(query["private_key"]))}))
    except (ValueError, KeyError):
        sys.exit("Cannot derive RSA service-account JWKS")
