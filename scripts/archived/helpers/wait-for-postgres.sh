#!/bin/bash
# Wait for PostgreSQL cluster to be ready
# Usage: ./wait-for-postgres.sh <claim-name> <namespace> [timeout]

set -euo pipefail

CLAIM_NAME="${1:?PostgresInstance claim name required}"
NAMESPACE="${2:?Namespace required}"
TIMEOUT="${3:-300}"

ELAPSED=0
INTERVAL=10

echo "Waiting for PostgreSQL cluster $CLAIM_NAME to be ready..."

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check if PostgresInstance exists
    if ! kubectl get postgresinstance "$CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "  PostgresInstance $CLAIM_NAME not found yet... (${ELAPSED}s elapsed)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
        continue
    fi
    
    # Check if CNPG cluster exists (created by Crossplane via Object resource)
    CLUSTER_EXISTS=$(kubectl get cluster "$CLAIM_NAME" -n "$NAMESPACE" 2>/dev/null && echo "true" || echo "false")
    
    if [ "$CLUSTER_EXISTS" = "false" ]; then
        echo "  Waiting for CNPG cluster to be created... (${ELAPSED}s elapsed)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
        continue
    fi
    
    # Check cluster status
    CLUSTER_STATUS=$(kubectl get cluster "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    READY_INSTANCES=$(kubectl get cluster "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
    TOTAL_INSTANCES=$(kubectl get cluster "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.instances}' 2>/dev/null || echo "0")
    
    echo "  Cluster: $CLAIM_NAME | Status: $CLUSTER_STATUS | Ready: $READY_INSTANCES/$TOTAL_INSTANCES (${ELAPSED}s elapsed)"
    
    # Check for pod failures (using CNPG label)
    POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster="$CLAIM_NAME" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$POD_STATUS" = "Failed" ] || [ "$POD_STATUS" = "CrashLoopBackOff" ]; then
        echo "✗ Pod is in failed state: $POD_STATUS"
        kubectl describe pods -n "$NAMESPACE" -l cnpg.io/cluster="$CLAIM_NAME"
        exit 1
    fi
    
    if [ "$CLUSTER_STATUS" = "Cluster in healthy state" ] && [ "$READY_INSTANCES" = "$TOTAL_INSTANCES" ] && [ "$READY_INSTANCES" != "0" ]; then
        echo "✓ PostgreSQL cluster $CLAIM_NAME is ready"
        exit 0
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "✗ Timeout waiting for PostgreSQL cluster after ${TIMEOUT}s"
echo ""
echo "=== Debugging Information ==="
echo "PostgresInstance details:"
kubectl describe postgresinstance "$CLAIM_NAME" -n "$NAMESPACE" 2>/dev/null || echo "Not found"
echo ""
echo "XPostgresInstance (composite) details:"
kubectl get xpostgresinstance -o yaml 2>/dev/null | grep -A 30 "$CLAIM_NAME" || echo "Not found"
echo ""
echo "Crossplane Object resources:"
kubectl get object -A 2>/dev/null | grep -i postgres || echo "No Object resources found"
echo ""
echo "CNPG Clusters in namespace:"
kubectl get cluster -n "$NAMESPACE" 2>/dev/null || echo "No clusters found"
echo ""
echo "Recent events in namespace:"
kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
exit 1
