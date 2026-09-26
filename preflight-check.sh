#!/usr/bin/env bash
set -uo pipefail

GKE_CLUSTER="aigw2-workshop"
GKE_REGION="us-east1"
GCP_PROJECT="sales-engineering-282713"
DNS_ZONE="sales-engineering"
HELM_REPO_NAME="kong"
HELM_REPO_URL="https://charts.konghq.com"

FIX=false
FAILED=false

usage() {
  echo "Usage: $0 [--fix]"
  echo "  --fix    Attempt to auto-fix problems (add helm repo, switch kubectl context)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix) FIX=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

ok()   { echo "  OK: $1"; }
fail() { echo "  FAIL: $1"; FAILED=true; }

echo "=== Preflight checks ==="

# ── CLI tools ────────────────────────────────────────────────────────────────
echo ""
echo "-- CLI tools --"
for tool in gcloud kubectl helm jq openssl curl; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool found ($(command -v "$tool"))"
  else
    fail "$tool not found on PATH"
  fi
done

# ── bash version ─────────────────────────────────────────────────────────────
echo ""
echo "-- bash version --"
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  ok "bash ${BASH_VERSION}"
else
  fail "bash ${BASH_VERSION} is too old (need bash 4+)"
fi

# ── gcloud auth ──────────────────────────────────────────────────────────────
echo ""
echo "-- gcloud auth --"
if command -v gcloud &>/dev/null; then
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
  if [[ -z "$ACTIVE_ACCOUNT" ]]; then
    fail "no active gcloud account — run 'gcloud auth login'"
  else
    echo -n "  Verifying token for $ACTIVE_ACCOUNT ... "
    if gcloud projects list --limit=1 &>/dev/null; then
      echo "OK"
    else
      echo "STALE"
      fail "gcloud account '$ACTIVE_ACCOUNT' is listed active but its token doesn't work — run 'gcloud auth login' (requires interactive browser OAuth, cannot be automated)"
    fi
  fi
else
  fail "gcloud not installed, skipping auth check"
fi

# ── helm kong repo ───────────────────────────────────────────────────────────
echo ""
echo "-- helm 'kong' repo --"
if command -v helm &>/dev/null; then
  if helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "$HELM_REPO_NAME"; then
    ok "helm repo '$HELM_REPO_NAME' already added"
  elif $FIX; then
    echo "  Adding helm repo '$HELM_REPO_NAME' ($HELM_REPO_URL) ..."
    if helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" &>/dev/null && helm repo update &>/dev/null; then
      ok "helm repo '$HELM_REPO_NAME' added"
    else
      fail "could not add helm repo '$HELM_REPO_NAME'"
    fi
  else
    fail "helm repo '$HELM_REPO_NAME' not added (rerun with --fix, or: helm repo add $HELM_REPO_NAME $HELM_REPO_URL)"
  fi
else
  fail "helm not installed, skipping repo check"
fi

# ── GKE cluster reachability + kubectl context ───────────────────────────────
echo ""
echo "-- GKE cluster ($GKE_CLUSTER / $GKE_REGION / $GCP_PROJECT) --"
if command -v gcloud &>/dev/null && command -v kubectl &>/dev/null; then
  CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
  if [[ "$CURRENT_CONTEXT" == *"$GKE_CLUSTER"* ]]; then
    ok "kubectl context already set to $CURRENT_CONTEXT"
  elif $FIX; then
    echo "  Fetching credentials for $GKE_CLUSTER ..."
    if gcloud container clusters get-credentials "$GKE_CLUSTER" \
        --region "$GKE_REGION" --project "$GCP_PROJECT" &>/dev/null; then
      ok "kubectl context switched to $GKE_CLUSTER"
    else
      fail "could not fetch credentials for cluster '$GKE_CLUSTER' in project '$GCP_PROJECT'"
    fi
  else
    fail "kubectl context is '$CURRENT_CONTEXT', not $GKE_CLUSTER (rerun with --fix, or: gcloud container clusters get-credentials $GKE_CLUSTER --region $GKE_REGION --project $GCP_PROJECT)"
  fi

  echo -n "  Checking cluster reachability ... "
  if kubectl cluster-info &>/dev/null; then
    echo "OK"
  else
    echo "FAIL"
    fail "kubectl cannot reach the cluster (check VPN/context)"
  fi
else
  fail "gcloud or kubectl not installed, skipping cluster check"
fi

# ── GCP DNS zone ──────────────────────────────────────────────────────────────
echo ""
echo "-- GCP DNS zone ($DNS_ZONE) --"
if command -v gcloud &>/dev/null; then
  if gcloud dns managed-zones describe "$DNS_ZONE" --project="$GCP_PROJECT" &>/dev/null; then
    ok "DNS zone '$DNS_ZONE' exists in project '$GCP_PROJECT'"
  else
    fail "DNS zone '$DNS_ZONE' not found in project '$GCP_PROJECT'"
  fi
else
  fail "gcloud not installed, skipping DNS check"
fi

echo ""
if $FAILED; then
  echo "=== Preflight FAILED ==="
  exit 1
else
  echo "=== Preflight OK ==="
  exit 0
fi
