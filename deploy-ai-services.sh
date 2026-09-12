#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-}"

if [[ -z "$NAMESPACE" ]]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

SECRET_NAME="cloudsmith-registry-secret"

read -rp "Cloudsmith username: " CS_USER
read -rsp "Cloudsmith password/token: " CS_PASS
echo ""

echo -n "Verifying Cloudsmith credentials ... "
http_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${CS_USER}:${CS_PASS}" \
  "https://docker.cloudsmith.io/v2/kong/ai-pii/service/tags/list")
if [[ "$http_code" != "200" ]]; then
  echo "FAILED (HTTP $http_code) — check your username and token"
  exit 1
fi
echo "OK"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating $SECRET_NAME in $NAMESPACE ..."
kubectl create secret docker-registry "$SECRET_NAME" \
  --docker-server=docker.cloudsmith.io \
  --docker-username="$CS_USER" \
  --docker-password="$CS_PASS" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "$NAMESPACE" -f - <<EOF
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
EOF

echo ""
echo "Waiting for rollout in namespace: $NAMESPACE"
kubectl rollout status deployment/kong-pii-sanitizer -n "$NAMESPACE"
kubectl rollout status deployment/redis-vector-db -n "$NAMESPACE"
echo "Done."
