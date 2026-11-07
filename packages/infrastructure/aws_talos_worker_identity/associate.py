"""Attach only to an unassociated existing instance. Never replace or detach."""
import json, os, subprocess

def aws(*args):
    return json.loads(subprocess.check_output(["aws", "--region", os.environ["ASSOCIATION_REGION"], "--output", "json", "ec2", *args]))
instance = os.environ["ASSOCIATION_INSTANCE"]
profile = os.environ["ASSOCIATION_PROFILE"]
current = aws("describe-iam-instance-profile-associations", "--filters", "Name=instance-id,Values=" + instance)["IamInstanceProfileAssociations"]
current = [a for a in current if a["State"] != "disassociated"]
if current:
    if len(current) != 1 or current[0]["IamInstanceProfile"]["Arn"] != profile:
        raise RuntimeError("Existing association differs; refusing replacement")
else:
    aws("associate-iam-instance-profile", "--instance-id", instance, "--iam-instance-profile", "Arn=" + profile)
print("Existing controller profile association accepted; no compute mutation")
