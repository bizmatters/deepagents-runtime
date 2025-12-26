#!/bin/bash
# Wait for Kubernetes Secret to be created
# Usage: ./wait-for-secret.sh <secret-name> <namespace> [timeout]

set -euo pipefail

SECRET_NAME="${1:?Secret name required}"
NAMESPACE="${2:?Namespace required}"
TIMEOUT="${3:-120}"

ELAPSED=0
INTERVAL=5

while [ $ELAPSED -lt $TIMEOUT ]; do
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "✓ Secret $SECRET_NAME created successfully"
        exit 0
    fi
    
    echo "  Waiting for secret $SECRET_NAME... (${ELAPSED}s elapsed)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "✗ Timeout waiting for secret $SECRET_NAME after ${TIMEOUT}s"
exit 1
