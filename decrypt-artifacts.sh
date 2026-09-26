#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <org>"
  echo ""
  echo "Decrypts deployments/<org>.tar.enc back into deployments/<org>/."
  echo ""
  echo "Passphrase is read from \$DEPLOY_ARTIFACTS_PASSPHRASE, or prompted for interactively."
  exit 1
}

[[ $# -eq 1 ]] || usage
ORG="$1"

IN_FILE="deployments/${ORG}.tar.enc"
DEST_DIR="deployments/$ORG"

if [[ ! -f "$IN_FILE" ]]; then
  echo "Error: $IN_FILE does not exist"
  exit 1
fi

if [[ -d "$DEST_DIR" ]]; then
  echo "Error: $DEST_DIR already exists — remove or move it aside before decrypting"
  exit 1
fi

if [[ -z "${DEPLOY_ARTIFACTS_PASSPHRASE:-}" ]]; then
  read -rsp "Passphrase: " DEPLOY_ARTIFACTS_PASSPHRASE
  echo ""
fi

echo "Decrypting $IN_FILE -> $DEST_DIR ..."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
  -pass env:DEPLOY_ARTIFACTS_PASSPHRASE \
  -in "$IN_FILE" | \
  tar -C deployments -xf -

echo "Done. Decrypted artifacts: $DEST_DIR"
