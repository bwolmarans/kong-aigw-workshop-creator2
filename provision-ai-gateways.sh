#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="2.0.3"

usage() {
  echo "Usage: $0 [options]"
  echo "  --konnect_pat <token>    Konnect PAT"
  echo "  --prefix <prefix>        Gateway name prefix (e.g. student)"
  echo "  --range <range>          Gateway range, e.g. 7 or 1-10"
  echo "  --org <org>              Konnect organisation name (used for folder)"
  echo "  --namespace <namespace>  Kubernetes namespace"
  echo "  --region <region>        Konnect region (default: us)"
  echo "  --apply-automatically    Skip deploy prompt and apply to all gateways"
  echo "  --router-only            Only create the AI Gateway Router, skip per-gateway loop"
  exit 1
}

KONNECT_TOKEN=""
PREFIX=""
RANGE=""
ORG=""
NAMESPACE=""
REGION="us"
APPLY_AUTOMATICALLY=false
ROUTER_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --konnect_pat) KONNECT_TOKEN="$2"; shift 2 ;;
    --prefix)      PREFIX="$2"; shift 2 ;;
    --range)       RANGE="$2"; shift 2 ;;
    --org)         ORG="$2"; shift 2 ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --apply-automatically) APPLY_AUTOMATICALLY=true; shift ;;
    --router-only) ROUTER_ONLY=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KONNECT_TOKEN" ]] && read -rp "Konnect PAT: " KONNECT_TOKEN
if ! $ROUTER_ONLY; then
  [[ -z "$PREFIX" ]]  && read -rp "Gateway name prefix (e.g. student): " PREFIX
  [[ -z "$RANGE" ]]   && read -rp "Gateway range (e.g. 7 or 1-10): " RANGE
fi
[[ -z "$ORG" ]]       && read -rp "Konnect organisation name (used for folder): " ORG
[[ -z "$NAMESPACE" ]] && read -rp "Kubernetes namespace: " NAMESPACE

KONNECT_URL="https://${REGION}.api.konghq.com/v1"
KONNECT_API="https://${REGION}.api.konghq.com"

# ── Vault key/value collection ─────────────────────────────────────────────────
VAULT_KEYS=()
VAULT_VALS=()
echo ""
echo "Enter key/value pairs to store in the 'ai' vault on each gateway."
while true; do
  read -rp "  Key (blank to finish): " vkey
  [[ -z "$vkey" ]] && break
  read -rp "  Value for '$vkey': " vval
  VAULT_KEYS+=("$vkey")
  VAULT_VALS+=("$vval")
done
echo "  ${#VAULT_KEYS[@]} key(s) collected."
echo ""

# ── Cloudsmith credentials ─────────────────────────────────────────────────────
if ! $ROUTER_ONLY; then
  read -rp "Cloudsmith username: " CS_USER
  read -rsp "Cloudsmith password/token: " CS_PASS
  echo ""
  echo -n "Verifying Cloudsmith credentials ... "
  cs_http=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${CS_USER}:${CS_PASS}" \
    "https://docker.cloudsmith.io/v2/kong/ai-pii/service/tags/list")
  if [[ "$cs_http" != "200" ]]; then
    echo "FAILED (HTTP $cs_http) — check your username and token"
    exit 1
  fi
  echo "OK"
  echo ""
fi

curl_with_retry() {
  local attempt response http_code
  for attempt in 1 2 3; do
    response=$(curl -sS -w '\n%{http_code}' "$@")
    http_code=$(tail -n1 <<< "$response")
    response=$(sed '$d' <<< "$response")
    if [[ "$http_code" != 5* ]]; then
      echo "$response"
      return 0
    fi
    [[ "$attempt" -lt 3 ]] && sleep 5
  done
  echo "$response"
  return 0
}


if [[ "$RANGE" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
  RANGE_START="${BASH_REMATCH[1]}"
  RANGE_END="${BASH_REMATCH[2]}"
elif [[ "$RANGE" =~ ^([1-9][0-9]*)$ ]]; then
  RANGE_START="${BASH_REMATCH[1]}"
  RANGE_END="${BASH_REMATCH[1]}"
else
  echo "Error: range must be a number (e.g. 7) or a range (e.g. 1-10)"
  exit 1
fi
if [[ "$RANGE_START" -gt "$RANGE_END" ]]; then
  echo "Error: range start ($RANGE_START) must be <= range end ($RANGE_END)"
  exit 1
fi
COUNT=$(( RANGE_END - RANGE_START + 1 ))

BASE_DIR="deployments/$ORG"
mkdir -p "$BASE_DIR"

echo -n "Switching kubectl context to aigw2-workshop ... "
gcloud container clusters get-credentials aigw2-workshop --region us-east1 --project sales-engineering-282713
echo "OK"

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null)
echo "  Current context: $CURRENT_CONTEXT"
if [[ "$CURRENT_CONTEXT" != *"aigw2-workshop"* ]]; then
  echo "ERROR: context does not appear to be aigw2-workshop — aborting"
  exit 1
fi

if ! $ROUTER_ONLY; then

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── Per-gateway loop ───────────────────────────────────────────────────────────
for i in $(seq "$RANGE_START" "$RANGE_END"); do
  GW_NAME="${PREFIX}-${i}"
  KONNECT_NAME="${PREFIX}${i}"
  GW_DIR="$BASE_DIR/$GW_NAME"
  mkdir -p "$GW_DIR"

  echo ""
  echo "=== [$i/$RANGE_END] $GW_NAME ==="

  # 1. Create the AI Gateway (or fetch existing on 409)
  echo -n "  Creating AI Gateway ... "
  raw=$(curl -sS -w '\n%{http_code}' -X POST "$KONNECT_URL/ai-gateways" \
    -H "Authorization: Bearer $KONNECT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$KONNECT_NAME\",
      \"display_name\": \"$KONNECT_NAME\",
      \"description\": \"AI Gateway $KONNECT_NAME\",
      \"labels\": {\"org\": \"$ORG\"}
    }")
  http_code=$(tail -n1 <<< "$raw")
  response=$(sed '$d' <<< "$raw")

  if [[ "$http_code" == 5* ]]; then
    echo "FAILED (HTTP $http_code)"
    echo "  API response: $response"
    continue
  fi

  if [[ "$http_code" == "409" ]]; then
    existing=$(curl_with_retry "$KONNECT_URL/ai-gateways?filter%5Bname%5D=$KONNECT_NAME" \
      -H "Authorization: Bearer $KONNECT_TOKEN")
    EXISTING_ID=$(echo "$existing" | jq -r '.data[0].id')
    if ! $APPLY_AUTOMATICALLY; then
      read -rp "  AI Gateway '$KONNECT_NAME' ($EXISTING_ID) already exists. Delete and recreate? [y/N] " del_answer </dev/tty
      if [[ "${del_answer,,}" != "y" ]]; then
        echo "  Skipping $GW_NAME"
        continue
      fi
    fi
    echo "already exists, deleting ... "
    curl_with_retry -X DELETE "$KONNECT_URL/ai-gateways/$EXISTING_ID" \
      -H "Authorization: Bearer $KONNECT_TOKEN" > /dev/null
    echo -n "  Deleted $EXISTING_ID, waiting for name to be released ..."
    raw=""
    http_code=""
    for attempt in $(seq 1 12); do
      sleep 10
      echo -n "."
      raw=$(curl -sS -w '\n%{http_code}' -X POST "$KONNECT_URL/ai-gateways" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
          \"name\": \"$KONNECT_NAME\",
          \"display_name\": \"$KONNECT_NAME\",
          \"description\": \"AI Gateway $KONNECT_NAME\",
          \"labels\": {\"org\": \"$ORG\"}
        }")
      http_code=$(tail -n1 <<< "$raw")
      response=$(sed '$d' <<< "$raw")
      if [[ "$http_code" == "201" ]]; then
        echo " OK"
        break
      elif [[ "$http_code" != "409" ]]; then
        echo " FAILED (HTTP $http_code)"
        echo "  API response: $response"
        break
      fi
      if [[ "$attempt" -eq 12 ]]; then
        echo " timed out waiting for name release"
      fi
    done
    if [[ "$http_code" != "201" ]]; then
      echo "FAILED (HTTP $http_code)"
      echo "  API response: $response"
      continue
    fi
  fi

  sleep 3
  GW_ID=$(echo "$response" | jq -r '.id')
  CP_URL=$(echo "$response" | jq -r '.endpoints.configuration')
  TP_URL=$(echo "$response" | jq -r '.endpoints.telemetry')

  if [[ "$GW_ID" == "null" || -z "$GW_ID" ]]; then
    echo "FAILED"
    echo "  API response: $response"
    continue
  fi
  echo "OK ($GW_ID)"

  # Strip https:// to get hostnames
  CP_HOST="${CP_URL#https://}"
  TP_HOST="${TP_URL#https://}"

  # 2. Generate TLS cert/key
  echo -n "  Generating TLS cert/key ... "
  openssl req -new -newkey rsa:2048 -days 1095 -nodes -x509 \
    -subj "/CN=$GW_NAME" \
    -keyout "$GW_DIR/tls.key" \
    -out "$GW_DIR/tls.crt" 2>/dev/null
  echo "OK"

  # 3. Register cert with AI Gateway
  echo -n "  Registering cert with Konnect ... "
  CERT_BODY=$(jq -Rs '.' < "$GW_DIR/tls.crt")
  cert_response=$(curl_with_retry -X POST "$KONNECT_URL/ai-gateways/$GW_ID/data-plane-certificates" \
    -H "Authorization: Bearer $KONNECT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"cert\": $CERT_BODY, \"title\": \"$GW_NAME\"}")

  sleep 3
  CERT_ID=$(echo "$cert_response" | jq -r '.id')
  if [[ "$CERT_ID" == "null" || -z "$CERT_ID" ]]; then
    echo "FAILED"
    echo "  API response: $cert_response"
    continue
  fi
  echo "OK ($CERT_ID)"

  # 4. Create config store and vault
  echo -n "  Creating config store ... "
  cs_response=$(curl_with_retry -X POST "$KONNECT_URL/ai-gateways/$GW_ID/config-stores" \
    -H "Authorization: Bearer $KONNECT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${GW_NAME}-vault-ai\"}")
  sleep 3
  CS_ID=$(echo "$cs_response" | jq -r '.id')
  if [[ "$CS_ID" == "null" || -z "$CS_ID" ]]; then
    echo "FAILED"
    echo "  API response: $cs_response"
    continue
  fi
  echo "OK ($CS_ID)"

  for j in "${!VAULT_KEYS[@]}"; do
    echo -n "  Storing secret '${VAULT_KEYS[$j]}' ... "
    sec_body=$(jq -n \
      --arg k "${VAULT_KEYS[$j]}" \
      --arg v "${VAULT_VALS[$j]}" \
      '{"key": $k, "value": $v}')
    sec_response=$(curl_with_retry -X POST "$KONNECT_URL/ai-gateways/$GW_ID/config-stores/$CS_ID/secrets" \
      -H "Authorization: Bearer $KONNECT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$sec_body")
    sleep 3
    sec_id=$(echo "$sec_response" | jq -r '.id // .key // empty')
    if [[ -z "$sec_id" ]]; then
      echo "FAILED"
      echo "    API response: $sec_response"
    else
      echo "OK"
    fi
  done

  echo -n "  Creating vault 'ai' ... "
  vault_response=$(curl_with_retry -X POST "$KONNECT_URL/ai-gateways/$GW_ID/vaults" \
    -H "Authorization: Bearer $KONNECT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"ai\", \"type\": \"konnect\", \"config\": {\"config_store_id\": \"$CS_ID\"}}")
  sleep 3
  VAULT_ID=$(echo "$vault_response" | jq -r '.id')
  if [[ "$VAULT_ID" == "null" || -z "$VAULT_ID" ]]; then
    echo "FAILED"
    echo "  API response: $vault_response"
    continue
  fi
  echo "OK ($VAULT_ID)"

  # 5. Write values.yaml
  cat > "$GW_DIR/values.yaml" <<EOF
ingressController:
  enabled: false

image:
  repository: kong/kong-ai-gateway
  tag: "$IMAGE_TAG"

secretVolumes:
  - ${GW_NAME}-cluster-cert

env:
  role: data_plane
  database: "off"
  konnect_mode: "on"
  vitals: "off"
  cluster_mtls: pki
  cluster_control_plane: "${CP_HOST}:443"
  cluster_server_name: "${CP_HOST}"
  cluster_telemetry_endpoint: "${TP_HOST}:443"
  cluster_telemetry_server_name: "${TP_HOST}"
  cluster_cert: /etc/secrets/${GW_NAME}-cluster-cert/tls.crt
  cluster_cert_key: /etc/secrets/${GW_NAME}-cluster-cert/tls.key
  lua_ssl_trusted_certificate: system
  proxy_access_log: "off"
  dns_stale_ttl: "3600"

resources:
  requests:
    cpu: 250m
    memory: "512Mi"

proxy:
  enabled: true
  type: ClusterIP

admin:
  enabled: false

manager:
  enabled: false
EOF
  echo "  values.yaml written"

  # 5. Show helm commands and prompt
  SECRET_NAME="${GW_NAME}-cluster-cert"
  SECRET_CMD="kubectl create secret tls $SECRET_NAME --cert=$GW_DIR/tls.crt --key=$GW_DIR/tls.key -n $NAMESPACE --create-namespace"
  HELM_CMD="helm upgrade --install $GW_NAME kong/kong -n $NAMESPACE --create-namespace -f $GW_DIR/values.yaml"

  echo ""
  echo "  Commands to run:"
  echo "    $SECRET_CMD"
  echo "    $HELM_CMD"
  echo ""

  if $APPLY_AUTOMATICALLY; then
    answer="y"
  else
    read -rp "  Deploy dataplane for $GW_NAME? [y/N] " answer </dev/tty
  fi

  if [[ "${answer,,}" == "y" ]]; then
    echo "  Creating TLS secret ..."
    kubectl create secret tls "$SECRET_NAME" \
      --cert="$GW_DIR/tls.crt" \
      --key="$GW_DIR/tls.key" \
      -n "$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -

    echo "  Running helm upgrade --install ..."
    helm upgrade --install "$GW_NAME" kong/kong -n "$NAMESPACE" --create-namespace -f "$GW_DIR/values.yaml" > /dev/null 2>&1

    # 6. Poll for dataplane node
    echo -n "  Waiting for dataplane to connect"
    for attempt in $(seq 1 12); do
      sleep 10
      node_count=$(curl_with_retry "$KONNECT_URL/ai-gateways/$GW_ID/nodes" \
        -H "Authorization: Bearer $KONNECT_TOKEN" | jq '.data | length')
      sleep 3
      if [[ "$node_count" -gt 0 ]]; then
        echo " connected ($node_count node(s))"
        break
      fi
      echo -n "."
      if [[ "$attempt" -eq 12 ]]; then
        echo " timed out (check manually)"
      fi
    done
  else
    echo "  Skipped deployment for $GW_NAME"
  fi

done

echo ""
echo "Done. AI Gateways written to $BASE_DIR/"

fi # --router-only skip

# ── Router control plane ───────────────────────────────────────────────────────
echo ""
echo "=== Router control plane ==="

echo -n "  Checking for existing 'AI Gateway Router' control plane ... "
existing_router=$(curl_with_retry "$KONNECT_API/v2/control-planes?filter%5Bname%5D=AI+Gateway+Router" \
  -H "Authorization: Bearer $KONNECT_TOKEN")
EXISTING_ROUTER_ID=$(echo "$existing_router" | jq -r '.data[0].id // empty')
if [[ -n "$EXISTING_ROUTER_ID" ]]; then
  if ! $APPLY_AUTOMATICALLY; then
    read -rp "  'AI Gateway Router' control plane ($EXISTING_ROUTER_ID) already exists. Delete and recreate? [y/N] " del_router_answer </dev/tty
    if [[ "${del_router_answer,,}" != "y" ]]; then
      echo "  Skipping router deletion — exiting"
      exit 1
    fi
  fi
  echo "found ($EXISTING_ROUTER_ID), deleting ... "
  curl_with_retry -X DELETE "$KONNECT_API/v2/control-planes/$EXISTING_ROUTER_ID" \
    -H "Authorization: Bearer $KONNECT_TOKEN" > /dev/null
  sleep 3
  echo "  Deleted, proceeding to create ..."
else
  echo "none found"
fi

if ! $APPLY_AUTOMATICALLY; then
  read -rp "  Create 'AI Gateway Router' control plane? [y/N] " create_router_answer </dev/tty
  if [[ "${create_router_answer,,}" != "y" ]]; then
    echo "  Skipping router creation"
    exit 0
  fi
fi

echo -n "  Creating 'AI Gateway Router' control plane ... "
router_raw=$(curl_with_retry -X POST "$KONNECT_API/v2/control-planes" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "AI Gateway Router", "cluster_type": "CLUSTER_TYPE_HYBRID"}')
sleep 3

ROUTER_CP_ID=$(echo "$router_raw" | jq -r '.id')
if [[ "$ROUTER_CP_ID" == "null" || -z "$ROUTER_CP_ID" ]]; then
  echo "FAILED"
  echo "  API response: $router_raw"
  exit 1
fi
echo "OK ($ROUTER_CP_ID)"

ROUTER_CP_HOST=$(echo "$router_raw" | jq -r '.config.control_plane_endpoint' | sed 's|https://||')
ROUTER_TP_HOST=$(echo "$router_raw" | jq -r '.config.telemetry_endpoint' | sed 's|https://||')

DP_NAME="ai-gateway-router"
DP_DIR="$BASE_DIR/$DP_NAME"
mkdir -p "$DP_DIR"

echo -n "  Generating TLS cert/key ... "
openssl req -new -newkey rsa:2048 -days 1095 -nodes -x509 \
  -subj "/CN=$DP_NAME" \
  -keyout "$DP_DIR/tls.key" \
  -out "$DP_DIR/tls.crt" 2>/dev/null
echo "OK"

echo -n "  Registering cert with Konnect ... "
ROUTER_CERT_BODY=$(jq -Rs '.' < "$DP_DIR/tls.crt")
router_cert_response=$(curl_with_retry -X POST "$KONNECT_API/v2/control-planes/$ROUTER_CP_ID/dp-client-certificates" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"cert\": $ROUTER_CERT_BODY}")
sleep 3

ROUTER_CERT_ID=$(echo "$router_cert_response" | jq -r '.item.id // .id')
if [[ "$ROUTER_CERT_ID" == "null" || -z "$ROUTER_CERT_ID" ]]; then
  echo "FAILED"
  echo "  API response: $router_cert_response"
  exit 1
fi
echo "OK ($ROUTER_CERT_ID)"

cat > "$DP_DIR/values.yaml" <<EOF
ingressController:
  enabled: false

image:
  repository: kong/kong-gateway
  tag: "3.9"

secretVolumes:
  - ${DP_NAME}-cluster-cert

env:
  role: data_plane
  database: "off"
  konnect_mode: "on"
  vitals: "off"
  cluster_mtls: pki
  cluster_control_plane: "${ROUTER_CP_HOST}:443"
  cluster_server_name: "${ROUTER_CP_HOST}"
  cluster_telemetry_endpoint: "${ROUTER_TP_HOST}:443"
  cluster_telemetry_server_name: "${ROUTER_TP_HOST}"
  cluster_cert: /etc/secrets/${DP_NAME}-cluster-cert/tls.crt
  cluster_cert_key: /etc/secrets/${DP_NAME}-cluster-cert/tls.key
  lua_ssl_trusted_certificate: system

proxy:
  enabled: true
  type: LoadBalancer

admin:
  enabled: false

manager:
  enabled: false
EOF
echo "  values.yaml written to $DP_DIR/values.yaml"

ROUTER_SECRET_CMD="kubectl create secret tls ${DP_NAME}-cluster-cert --cert=$DP_DIR/tls.crt --key=$DP_DIR/tls.key -n $NAMESPACE --create-namespace"
ROUTER_HELM_CMD="helm upgrade --install $DP_NAME kong/kong -n $NAMESPACE --create-namespace -f $DP_DIR/values.yaml"

echo ""
echo "  Commands to run:"
echo "    $ROUTER_SECRET_CMD"
echo "    $ROUTER_HELM_CMD"
echo ""

if ! $APPLY_AUTOMATICALLY; then
  read -rp "  Deploy router dataplane, PII sanitizer, Redis, and per-student routes? [y/N] " deploy_router_answer </dev/tty
  [[ "${deploy_router_answer,,}" == "y" ]] && APPLY_AUTOMATICALLY=true || true
fi

if $APPLY_AUTOMATICALLY; then
  echo "  Creating namespace and TLS secret ..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
  kubectl create secret tls "${DP_NAME}-cluster-cert" \
    --cert="$DP_DIR/tls.crt" \
    --key="$DP_DIR/tls.key" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "  Running helm upgrade --install ..."
  if helm status "$DP_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "  Existing Helm release found, uninstalling first to clear field manager conflicts ..."
    helm uninstall "$DP_NAME" -n "$NAMESPACE"
    sleep 5
  fi
  helm upgrade --install "$DP_NAME" kong/kong -n "$NAMESPACE" --create-namespace -f "$DP_DIR/values.yaml"

  echo -n "  Waiting for LoadBalancer external IP"
  EXTERNAL_IP=""
  for attempt in $(seq 1 24); do
    sleep 10
    EXTERNAL_IP=$(kubectl get svc "${DP_NAME}-kong-proxy" -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$EXTERNAL_IP" ]]; then
      echo " got $EXTERNAL_IP"
      break
    fi
    echo -n "."
    if [[ "$attempt" -eq 24 ]]; then
      echo " FAILED (timed out waiting for external IP)"
      exit 1
    fi
  done

  DNS_ZONE="sales-engineering"
  GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
  DNS_SUFFIX=$(gcloud dns managed-zones describe "$DNS_ZONE" --project="$GCP_PROJECT" \
    --format="value(dnsName)" 2>/dev/null | sed 's/\.$//')
  FQDN="aigw-${NAMESPACE}.${DNS_SUFFIX}"

  echo "  Upserting DNS record ${FQDN} -> ${EXTERNAL_IP} ..."
  if gcloud dns record-sets describe "${FQDN}." \
      --zone="$DNS_ZONE" --type=A --project="$GCP_PROJECT" &>/dev/null; then
    gcloud dns record-sets update "${FQDN}." \
      --zone="$DNS_ZONE" \
      --type=A \
      --ttl=300 \
      --rrdatas="$EXTERNAL_IP" \
      --project="$GCP_PROJECT"
    echo "  DNS record updated: $FQDN"
  else
    gcloud dns record-sets create "${FQDN}." \
      --zone="$DNS_ZONE" \
      --type=A \
      --ttl=300 \
      --rrdatas="$EXTERNAL_IP" \
      --project="$GCP_PROJECT"
    echo "  DNS record created: $FQDN"
  fi

  # ── Deploy PII sanitizer + Redis ────────────────────────────────────────────
  echo "  Deploying PII sanitizer and Redis into namespace $NAMESPACE ..."

  echo "  Creating Cloudsmith pull secret ..."
  kubectl create secret docker-registry cloudsmith-registry-secret \
    --docker-server=docker.cloudsmith.io \
    --docker-username="$CS_USER" \
    --docker-password="$CS_PASS" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -n "$NAMESPACE" -f - <<'KUBEEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kong-pii-sanitizer
  labels:
    app: kong-pii-sanitizer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kong-pii-sanitizer
  template:
    metadata:
      labels:
        app: kong-pii-sanitizer
    spec:
      imagePullSecrets:
        - name: cloudsmith-registry-secret
      nodeSelector:
        cloud.google.com/gke-nodepool: larger-node-pool
      containers:
        - name: pii-sanitizer
          image: docker.cloudsmith.io/kong/ai-pii/service:v0.2.2-en
          args: ["--host", "0.0.0.0", "--port", "8080"]
          ports:
            - name: http-port
              containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 1Gi
            limits:
              cpu: 500m
              memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: kong-pii-sanitizer-service
spec:
  type: ClusterIP
  selector:
    app: kong-pii-sanitizer
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-vector-db
  labels:
    app: redis-vector-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-vector-db
  template:
    metadata:
      labels:
        app: redis-vector-db
    spec:
      nodeSelector:
        cloud.google.com/gke-nodepool: larger-node-pool
      containers:
        - name: redis
          image: redis/redis-stack-server:latest
          ports:
            - name: redis-port
              containerPort: 6379
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis-vector-service
spec:
  type: ClusterIP
  selector:
    app: redis-vector-db
  ports:
    - port: 6379
      targetPort: 6379
KUBEEOF

  echo "  Waiting for PII sanitizer rollout ..."
  kubectl rollout status deployment/kong-pii-sanitizer -n "$NAMESPACE"
  echo "  Waiting for Redis rollout ..."
  kubectl rollout status deployment/redis-vector-db -n "$NAMESPACE"

  echo "  Creating per-student services and routes ..."
  for i in $(seq "$RANGE_START" "$RANGE_END"); do
    SVC_HOST="${PREFIX}-${i}-kong-proxy"
    ROUTE_NAME="${PREFIX}${i}"

    echo -n "    [$i/$RANGE_END] service $SVC_HOST ... "
    svc_response=$(curl_with_retry -X POST \
      "$KONNECT_API/v2/control-planes/$ROUTER_CP_ID/core-entities/services" \
      -H "Authorization: Bearer $KONNECT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$SVC_HOST\", \"host\": \"$SVC_HOST\", \"port\": 80, \"protocol\": \"http\"}")
    sleep 3

    SVC_ID=$(echo "$svc_response" | jq -r '.id')
    if [[ "$SVC_ID" == "null" || -z "$SVC_ID" ]]; then
      echo "FAILED"
      echo "      API response: $svc_response"
      continue
    fi
    echo -n "OK ($SVC_ID) / route $ROUTE_NAME ... "

    route_response=$(curl_with_retry -X POST \
      "$KONNECT_API/v2/control-planes/$ROUTER_CP_ID/core-entities/services/$SVC_ID/routes" \
      -H "Authorization: Bearer $KONNECT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$ROUTE_NAME\", \"paths\": [\"/$ROUTE_NAME\"], \"strip_path\": true, \"protocols\": [\"http\", \"https\"]}")
    sleep 3

    ROUTE_ID=$(echo "$route_response" | jq -r '.id')
    if [[ "$ROUTE_ID" == "null" || -z "$ROUTE_ID" ]]; then
      echo "FAILED"
      echo "      API response: $route_response"
    else
      echo "OK ($ROUTE_ID)"
    fi
  done
else
  echo "  Skipped router deployment (--apply-automatically not set)"
fi

echo ""
echo "================================================"
echo "Done. All artifacts written to $BASE_DIR/"
echo "Router control plane ID: $ROUTER_CP_ID"
echo "================================================"
