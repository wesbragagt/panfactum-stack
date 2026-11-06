#!/usr/bin/env bash
set -euo pipefail
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
cp "$(dirname "$0")/kustomization.yaml" "$work_dir/kustomization.yaml"
cat >"$work_dir/resources.yaml"
kustomize build "$work_dir"
