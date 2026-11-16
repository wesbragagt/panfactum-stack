#!/usr/bin/env bash

set -euo pipefail

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")
WORKDIR=$(mktemp -d)
trap 'rm -rf -- "$WORKDIR"' EXIT

# Helm may run this concurrently. Keep generated patches outside the source
# directory, whose files are hashed into the workload customization label.
cp -a "$SCRIPTPATH/." "$WORKDIR/"

# save manifests to files
printf '%s\n' "$1" >"$WORKDIR/destination.yaml"
printf '%s\n' "$2" >"$WORKDIR/identity.yaml"
printf '%s\n' "$3" >"$WORKDIR/proxy-injector.yaml"

# save incoming YAML to file
cat <&0 >"$WORKDIR/all.yaml"

# run kustomize
kustomize build "$WORKDIR"
