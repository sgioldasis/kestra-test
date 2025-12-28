#!/bin/bash
set -e
NAMESPACE="kestra"
RELEASE_NAME="kestra"

lsof -ti :8080 | xargs kill -9 > /dev/null 2>&1 || true
helm uninstall $RELEASE_NAME -n $NAMESPACE || true
kubectl delete namespace $NAMESPACE --wait=false
echo "[INFO] Kestra uninstalled."
