#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${VAULT_ADDR:?}" "${VAULT_ROLE:?}" "${VAULT_AUTH_MOUNT:?}" "${VAULT_JWT_FILE:?}"
: "${BACKUP_BUCKET:?}" "${BACKUP_PREFIX:?}" "${BACKUP_KMS_KEY_ARN:?}" "${POD_UID:?}"
: "${AWS_ROLE_ARN:?}" "${AWS_WEB_IDENTITY_TOKEN_FILE:?}"

# Only projected web identity may supply AWS credentials. Never fall back to IMDS.
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""

work_dir="${WORK_DIR:-/work}"
snapshot_file="${work_dir}/snapshot"
readback_file="${work_dir}/readback"
vault_token=""
cleanup() {
  if [[ -n "$vault_token" ]]; then
    printf 'X-Vault-Token: %s\n' "$vault_token" |
      curl --silent --show-error --fail --max-time 10 --request POST \
        --header @- "${VAULT_ADDR}/v1/auth/token/revoke-self" >/dev/null || true
  fi
  rm -f "$snapshot_file" "$readback_file"
  rm -rf "${work_dir:?}/cli/cache"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# JWT and resulting API token stay in files/stdin or process memory, never argv.
vault_token="$(jq -n --arg role "$VAULT_ROLE" --rawfile jwt "$VAULT_JWT_FILE" \
  '{role: $role, jwt: $jwt}' |
  curl --silent --show-error --fail --max-time 30 --header 'Content-Type: application/json' \
    --data-binary @- "${VAULT_ADDR}/v1/auth/${VAULT_AUTH_MOUNT}/login" |
  jq -er '.auth.client_token | select(length > 0)')"

# Every run checks that the issued policy can read snapshots but cannot read KV.
capabilities="$(
  {
    printf 'X-Vault-Token: %s\n' "$vault_token"
    printf 'Content-Type: application/json\n'
  } | curl --silent --show-error --fail --max-time 30 --header @- \
    --data '{"paths":["sys/storage/raft/snapshot","secret/data/backup-capability-probe"]}' \
    "${VAULT_ADDR}/v1/sys/capabilities-self"
)"
jq -e '.data["sys/storage/raft/snapshot"] == ["read"] and
       .data["secret/data/backup-capability-probe"] == ["deny"]' <<<"$capabilities" >/dev/null

printf 'X-Vault-Token: %s\n' "$vault_token" |
  curl --silent --show-error --fail --max-time 90 --header @- \
    --output "$snapshot_file" "${VAULT_ADDR}/v1/sys/storage/raft/snapshot"
snapshot_size="$(wc -c <"$snapshot_file")"
[[ "$snapshot_size" -gt 0 && "$snapshot_size" -le "${MAX_SNAPSHOT_BYTES:-67108864}" ]]
checksum="$(sha256sum "$snapshot_file" | cut -d ' ' -f 1)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
object_key="${BACKUP_PREFIX%/}/$(date -u +%Y/%m/%d)/${stamp}-${POD_UID}.snapshot"

# One bounded object, with create-only semantics and the bucket's exact key.
aws s3api put-object --bucket "$BACKUP_BUCKET" --key "$object_key" \
  --body "$snapshot_file" --if-none-match '*' --server-side-encryption aws:kms \
  --ssekms-key-id "$BACKUP_KMS_KEY_ARN" --metadata "sha256=$checksum" >/dev/null
head="$(aws s3api head-object --bucket "$BACKUP_BUCKET" --key "$object_key")"
jq -e --arg key "$BACKUP_KMS_KEY_ARN" --arg checksum "$checksum" \
  '.ServerSideEncryption == "aws:kms" and .SSEKMSKeyId == $key and .Metadata.sha256 == $checksum' \
  <<<"$head" >/dev/null
aws s3api get-object --bucket "$BACKUP_BUCKET" --key "$object_key" "$readback_file" >/dev/null
[[ "$(sha256sum "$readback_file" | cut -d ' ' -f 1)" == "$checksum" ]]

# Only non-secret object metadata goes to logs. Raw snapshots never do.
jq -cn --arg bucket "$BACKUP_BUCKET" --arg key "$object_key" --arg sha256 "$checksum" \
  --argjson bytes "$snapshot_size" '{status:"verified",bucket:$bucket,key:$key,sha256:$sha256,bytes:$bytes}'
