#!/bin/bash
# Wait for ExternalSecret to sync and create Kubernetes Secret
# Usage: ./wait-for-externalsecret.sh <externalsecret-name> <namespace> [timeout]

set -euo pipefail

ES_NAME="${1:?ExternalSecret name required}"
NAMESPACE="${2:?Namespace required}"
TIMEOUT="${3:-120}"

ELAPSED=0
INTERVAL=5

echo "Waiting for ExternalSecret $ES_NAME to sync..."

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check if secret exists
    if kubectl get secret "$ES_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "✓ Secret $ES_NAME created successfully by ExternalSecret"
        exit 0
    fi
    
    # Check ExternalSecret status
    ES_STATUS=$(kubectl get externalsecret "$ES_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")
    echo "  ExternalSecret status: $ES_STATUS (${ELAPSED}s elapsed)"
    
    # Fail fast on sync errors
    if [ "$ES_STATUS" = "SecretSyncedError" ]; then
        echo "✗ ExternalSecret failed to sync. Details:"
        kubectl describe externalsecret "$ES_NAME" -n "$NAMESPACE"
        exit 1
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "✗ Timeout waiting for ExternalSecret $ES_NAME after ${TIMEOUT}s"
echo "ExternalSecret details:"
kubectl describe externalsecret "$ES_NAME" -n "$NAMESPACE"
exit 1
