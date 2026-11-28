#!/usr/bin/env python3
"""Build an operator kubeconfig and obtain a Kubernetes exec credential for Talos IAM login."""

import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
from urllib.parse import urlsplit


ROLES = ("Superuser", "Admin", "Reader", "RestrictedReader")
STS_CLAIMS = "https://sts.amazonaws.com/"
ROLE_ARN = r"arn:([^:]+):iam::(\d{{12}}):role/aws-reserved/sso\.amazonaws\.com/(?:[\w-]+/)?(AWSReservedSSO_{}_[0-9a-f]+)"
PRINCIPAL_ARN = r"arn:([^:]+):iam::(\d{12}):(root|(?:user|role)/[\w+=,.@/-]+)"
SESSION_ARN = r"arn:([^:]+):sts::(\d{12}):assumed-role/([^/]+)/[^/]+"


def load_config(path):
    config = json.loads(path.read_text())
    if not isinstance(config, dict):
        raise ValueError("invalid operator metadata")
    for field in ("issuer", "audience", "region"):
        if not isinstance(config.get(field), str) or not config[field].strip():
            raise ValueError(f"operator metadata requires {field}")
    issuer = urlsplit(config["issuer"])
    if issuer.scheme != "https" or not issuer.hostname or issuer.username or issuer.query or issuer.fragment:
        raise ValueError("operator issuer must be an HTTPS URL")
    roles = config.get("role_arns")
    if not isinstance(roles, dict) or roles.keys() != set(ROLES):
        raise ValueError("operator metadata requires the four Panfactum role ARNs")
    accounts = set()
    for name, arn in roles.items():
        role = re.fullmatch(ROLE_ARN.format(name), arn) if isinstance(arn, str) else None
        if not role:
            raise ValueError(f"invalid Identity Center role ARN for {name}")
        accounts.add(role.groups()[:2])
    principals = config.get("principal_arns", [])
    if not isinstance(principals, list):
        raise ValueError("operator principal_arns must be a list")
    for arn in principals:
        principal = re.fullmatch(PRINCIPAL_ARN, arn) if isinstance(arn, str) else None
        if not principal:
            raise ValueError(f"invalid IAM principal ARN {arn}")
        accounts.add(principal.groups()[:2])
    if len(accounts) != 1:
        raise ValueError("operator ARNs must belong to one AWS account")
    return config


def aws_json(args, config, operation, *options):
    command = [
        args.aws_cli, "sts", operation, "--profile", args.profile, "--region", config["region"],
        "--output", "json", "--no-cli-pager", *options,
    ]
    try:
        result = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            env={**os.environ, "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true"}, timeout=45, check=True,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        raise ValueError(f"AWS STS {operation} failed for profile {args.profile}") from None


def credential(config, args):
    identity = aws_json(args, config, "get-caller-identity")
    session = re.fullmatch(SESSION_ARN, identity["Arn"])
    role_arns = config["role_arns"]
    principal_arns = config.get("principal_arns", [])
    selected = None
    if session:
        for name, arn in role_arns.items():
            role = re.fullmatch(ROLE_ARN.format(name), arn)
            if session.groups() == role.groups() and identity["Account"] == role[2]:
                selected = arn
                break
        # NOTE: IAM role names are unique per account, so the session name identifies an extra role ARN.
        for arn in principal_arns:
            if arn.startswith(f"arn:{session[1]}:iam::{session[2]}:role/") and arn.rsplit("/", 1)[-1] == session[3]:
                selected = arn
    elif identity["Arn"] in principal_arns:
        selected = identity["Arn"]
    if not selected:
        raise ValueError(f"AWS profile {args.profile} is not an approved Identity Center role or account root")

    response = aws_json(args, config, "get-web-identity-token", "--audience", config["audience"],
                        "--duration-seconds", "300", "--signing-algorithm", "RS256")
    try:
        token = response["WebIdentityToken"]
        _, encoded, _ = token.split(".")
        claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        expiration = datetime.datetime.fromtimestamp(claims["exp"], datetime.timezone.utc)
        sts_expiration = datetime.datetime.fromisoformat(response["Expiration"])
        audience = claims["aud"]
        valid = (
            claims["iss"] == config["issuer"]
            and audience in (config["audience"], [config["audience"]])
            and claims["sub"] == claims[STS_CLAIMS]["principal_id"] == selected
            and datetime.datetime.now(datetime.timezone.utc) < expiration
            and int(sts_expiration.timestamp()) == int(expiration.timestamp())
        )
    except (KeyError, ValueError, TypeError, OverflowError, OSError):
        valid = False
    if not valid:
        raise ValueError("AWS STS token claims do not match the selected profile and cluster")
    return {
        "apiVersion": "client.authentication.k8s.io/v1",
        "kind": "ExecCredential",
        "status": {"token": token, "expirationTimestamp": expiration.isoformat()},
    }


def kubeconfig(config, args):
    server = urlsplit(args.server)
    if (server.scheme != "https" or server.hostname not in ("127.0.0.1", "::1")
            or not server.port or server.username or server.path not in ("", "/")
            or server.query or server.fragment):
        raise ValueError("operator Kubernetes endpoint must be an HTTPS loopback URL with a port")
    ca_data = args.ca_data.strip()
    try:
        ssl.create_default_context(cadata=base64.b64decode(ca_data, validate=True).decode("ascii"))
    except (ValueError, ssl.SSLError):
        raise ValueError("operator CA must be a base64-encoded PEM certificate") from None
    cluster = config["audience"]
    name = f"{cluster}/{args.profile}"
    return {
        "apiVersion": "v1", "kind": "Config", "current-context": name,
        "clusters": [{"name": cluster, "cluster": {"server": args.server, "certificate-authority-data": ca_data}}],
        "contexts": [{"name": name, "context": {"cluster": cluster, "user": name}}],
        "users": [{"name": name, "user": {"exec": {
            "apiVersion": "client.authentication.k8s.io/v1",
            "interactiveMode": "Never",
            "command": sys.executable,
            "args": [
                str(Path(__file__).resolve()), "credential", "--config", str(args.config.resolve()),
                "--profile", args.profile, "--aws-cli", args.aws_cli,
            ],
        }}}],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    for operation in ("credential", "kubeconfig"):
        subcommand = commands.add_parser(operation)
        subcommand.add_argument("--config", type=Path, required=True)
        subcommand.add_argument("--profile", required=True)
        subcommand.add_argument("--aws-cli", default="aws")
        if operation == "kubeconfig":
            subcommand.add_argument("--server", required=True)
            subcommand.add_argument("--ca-data", required=True)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        result = kubeconfig(config, args) if args.operation == "kubeconfig" else credential(config, args)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"IAM login: {error}\n")


if __name__ == "__main__":
    main()
