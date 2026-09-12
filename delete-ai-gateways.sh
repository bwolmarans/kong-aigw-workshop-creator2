#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <konnect-pat>"
  exit 1
}

[[ $# -ne 1 ]] && usage

KONNECT_TOKEN="$1"
KONNECT_URL="https://us.api.konghq.com/v1"

gateways=$(curl -sS "$KONNECT_URL/ai-gateways" \
  -H "Authorization: Bearer $KONNECT_TOKEN" | jq -c '.data[]')

if [[ -z "$gateways" ]]; then
  echo "No AI Gateways found."
  exit 0
fi

while IFS= read -r gw; do
  id=$(echo "$gw" | jq -r '.id')
  name=$(echo "$gw" | jq -r '.name')

  read -rp "Delete '$name' ($id)? [y/N] " answer </dev/tty
  if [[ "${answer,,}" == "y" ]]; then
    curl -sS -X DELETE "$KONNECT_URL/ai-gateways/$id" \
      -H "Authorization: Bearer $KONNECT_TOKEN"
    echo "Deleted $name"
  else
    echo "Skipped $name"
  fi
done <<< "$gateways"
