#!/bin/bash
set -e
NAMESPACE="kestra"
FLOWS_DIR="flows"
FLOW_CONFIGMAP="kestra-local-flows"
DEPLOYMENT_NAME="kestra-starter-standalone"

echo "[INFO] Syncing flows..."
kubectl create configmap $FLOW_CONFIGMAP --from-file="$FLOWS_DIR" -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/$DEPLOYMENT_NAME -n $NAMESPACE
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=standalone -n $NAMESPACE --timeout=120s
lsof -ti :8080 | xargs kill -9 > /dev/null 2>&1 || true
(kubectl port-forward svc/kestra-starter 8080:8080 -n $NAMESPACE > /dev/null 2>&1 &)
echo "[INFO] Sync complete and port-forward restored."
