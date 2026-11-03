#!/usr/bin/env bash

set -eo pipefail

#####################################################
# Step 1: Clone the repo
#####################################################
cd /code
pf wf git-checkout \
  -r "$REPO" \
  -c "$GIT_REF" \
  -u "$GIT_USERNAME" \
  -p "$GIT_PASSWORD"
cd repo

# Repo-local checkout credentials do not cover git ls-remote against another private repo.
# Keep credentials in the environment rather than writing the token into the config.
# Expand only when Git invokes the helper, not while writing its configuration.
# shellcheck disable=SC2016
git config --global credential.https://github.com.helper '!f() { printf "%s\n" "username=$GIT_USERNAME" "password=$GIT_PASSWORD"; }; f'

#####################################################
# Step 2: Setup AWS profile
#####################################################
export AWS_CONFIG_FILE="/.aws/config"
cat >"$AWS_CONFIG_FILE" <<EOF
[profile ci]
role_arn = $AWS_ROLE_ARN
web_identity_token_file = /var/run/secrets/eks.amazonaws.com/serviceaccount/token
role_session_name = ci-runner
EOF

#####################################################
# Step 3: Get the lock table and region
#####################################################
# Match deploy.sh before terragrunt evaluates SOPS-backed locals.
pf wf sops-set-profile . ci

TG_VARIABLES=$(pf config get --directory "$TF_APPLY_DIR")
LOCK_TABLE=$(echo "$TG_VARIABLES" | jq '.tf_state_lock_table' -r)
LOCK_TABLE_REGION=$(echo "$TG_VARIABLES" | jq '.tf_state_region' -r)

#####################################################
# Step 4: Unlock
#####################################################
pf iac delete-locks \
  --profile ci \
  --region "$LOCK_TABLE_REGION" \
  --table "$LOCK_TABLE" \
  --who "$WHO"
