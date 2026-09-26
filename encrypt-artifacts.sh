#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <org>"
  echo ""
  echo "Tars and AES-256-CBC encrypts deployments/<org>/ into deployments/<org>.tar.enc,"
  echo "then deletes the plaintext directory."
  echo ""
  echo "Passphrase is read from \$DEPLOY_ARTIFACTS_PASSPHRASE, or prompted for interactively."
  exit 1
}

[[ $# -eq 1 ]] || usage
ORG="$1"

SRC_DIR="deployments/$ORG"
OUT_FILE="deployments/${ORG}.tar.enc"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: $SRC_DIR does not exist"
  exit 1
fi

if [[ -z "${DEPLOY_ARTIFACTS_PASSPHRASE:-}" ]]; then
  read -rsp "Passphrase: " DEPLOY_ARTIFACTS_PASSPHRASE
  echo ""
  read -rsp "Confirm passphrase: " CONFIRM_PASSPHRASE
  echo ""
  if [[ "$DEPLOY_ARTIFACTS_PASSPHRASE" != "$CONFIRM_PASSPHRASE" ]]; then
    echo "Error: passphrases do not match"
    exit 1
  fi
fi

echo "Encrypting $SRC_DIR -> $OUT_FILE ..."
tar -C deployments -cf - "$ORG" | \
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
    -pass env:DEPLOY_ARTIFACTS_PASSPHRASE \
    -out "$OUT_FILE"

echo "Removing plaintext $SRC_DIR ..."
rm -rf "$SRC_DIR"

echo "Done. Encrypted artifact: $OUT_FILE"
