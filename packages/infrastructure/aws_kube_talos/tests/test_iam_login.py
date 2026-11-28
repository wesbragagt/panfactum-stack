import base64
import datetime
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/iam_login.py"
spec = importlib.util.spec_from_file_location("iam_login", SCRIPT)
iam = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iam)

ACCOUNT = "123456789012"
ROLE_PATH = f"arn:aws:iam::{ACCOUNT}:role/aws-reserved/sso.amazonaws.com/"
CONFIG = {
    "issuer": "https://canary.tokens.sts.global.api.aws",
    "audience": "canary",
    "region": "us-east-2",
    "role_arns": {role: f"{ROLE_PATH}AWSReservedSSO_{role}_abcd" for role in iam.ROLES},
}
ARGS = SimpleNamespace(
    profile="homelab-reader",
    aws_cli="aws",
    config=Path("operator.json"),
    server="https://127.0.0.1:16443",
    ca_data=base64.b64encode(b"mock public CA").decode(),
)


def caller(role):
    return {"Arn": f"arn:aws:sts::{ACCOUNT}:assumed-role/AWSReservedSSO_{role}_abcd/session", "Account": ACCOUNT}


def token_response(role="Reader", **changes):
    expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5)
    arn = CONFIG["role_arns"][role]
    claims = {
        "iss": CONFIG["issuer"], "aud": CONFIG["audience"], "exp": int(expiry.timestamp()),
        "sub": arn, iam.STS_CLAIMS: {"principal_id": arn}, **changes,
    }
    encoded = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return {"WebIdentityToken": f"header.{encoded}.signature", "Expiration": expiry.isoformat()}


class IamLoginTest(unittest.TestCase):
    def test_both_sts_calls_use_same_selected_profile(self):
        response = token_response(aud=[CONFIG["audience"]])
        values = [caller("Reader"), response]
        results = [SimpleNamespace(stdout=json.dumps(value)) for value in values]
        with patch.object(iam.subprocess, "run", side_effect=results) as run:
            credential = iam.credential(CONFIG, ARGS)
        for call, operation in zip(run.call_args_list, ("get-caller-identity", "get-web-identity-token")):
            command = call.args[0]
            self.assertEqual(command[:7], ["aws", "sts", operation, "--profile", ARGS.profile,
                                           "--region", CONFIG["region"]])
        self.assertIn(CONFIG["audience"], run.call_args.args[0])
        self.assertEqual(credential["kind"], "ExecCredential")
        self.assertEqual(credential["status"]["token"], response["WebIdentityToken"])

    def test_billing_cannot_mint_through_helper(self):
        with patch.object(iam, "aws_json", return_value=caller("BillingAdmin")) as aws:
            with self.assertRaisesRegex(ValueError, "not an approved Identity Center role or account root"):
                iam.credential(CONFIG, ARGS)
            self.assertEqual(aws.call_count, 1)

    def test_account_root_gets_credential(self):
        root = f"arn:aws:iam::{ACCOUNT}:root"
        response = token_response(sub=root, **{iam.STS_CLAIMS: {"principal_id": root}})
        values = [{"Arn": root, "Account": ACCOUNT}, response]
        with patch.object(iam, "aws_json", side_effect=values):
            credential = iam.credential(CONFIG, ARGS)
        self.assertEqual(credential["kind"], "ExecCredential")
        self.assertEqual(credential["status"]["token"], response["WebIdentityToken"])

    def test_root_from_another_account_cannot_mint(self):
        identity = {"Arn": "arn:aws:iam::999999999999:root", "Account": "999999999999"}
        with patch.object(iam, "aws_json", return_value=identity) as aws:
            with self.assertRaisesRegex(ValueError, "not an approved Identity Center role or account root"):
                iam.credential(CONFIG, ARGS)
            self.assertEqual(aws.call_count, 1)

    def test_minted_token_must_match_caller_issuer_audience_and_expiration(self):
        for changes in (
            {"role": "Superuser"},
            {"iss": "https://other.example"},
            {"aud": "other-cluster"},
            {"aud": [CONFIG["audience"], "other-cluster"]},
            {"exp": 10},
            {iam.STS_CLAIMS: {"principal_id": CONFIG["role_arns"]["Admin"]}},
        ):
            values = [caller("Reader"), token_response(**changes)]
            with self.subTest(changes=changes), patch.object(iam, "aws_json", side_effect=values):
                with self.assertRaisesRegex(ValueError, "do not match"):
                    iam.credential(CONFIG, ARGS)

    def test_operator_config_contains_only_public_metadata_and_exec(self):
        with patch.object(iam.ssl, "create_default_context"):
            config = iam.kubeconfig(CONFIG, ARGS)
        cluster = config["clusters"][0]["cluster"]
        user = config["users"][0]["user"]
        self.assertEqual(cluster, {"server": ARGS.server, "certificate-authority-data": ARGS.ca_data})
        self.assertEqual(list(user), ["exec"])
        self.assertIn("--profile", user["exec"]["args"])
        self.assertIn(ARGS.profile, user["exec"]["args"])
        self.assertEqual(user["exec"]["interactiveMode"], "Never")

    def test_config_accepts_terraform_output_and_rejects_missing_role(self):
        # Mirrors `tofu output -json iam_login`, where a role without a match is null.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "operator.json"
            for config, valid in ((CONFIG, True), ({**CONFIG, "role_arns": {**CONFIG["role_arns"], "Admin": None}}, False)):
                path.write_text(json.dumps(config))
                with self.subTest(valid=valid):
                    if valid:
                        self.assertEqual(iam.load_config(path), CONFIG)
                    else:
                        with self.assertRaisesRegex(ValueError, "invalid Identity Center role ARN for Admin"):
                            iam.load_config(path)


if __name__ == "__main__":
    unittest.main()
