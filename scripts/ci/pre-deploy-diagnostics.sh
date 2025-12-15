#!/bin/bash
# Pre-Deploy Diagnostics - Show cluster resource usage and health before deployment
# Usage: ./pre-deploy-diagnostics.sh

set -euo pipefail

# Colors
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "================================================================================"
echo "DeepAgents Runtime - Service Dependencies Diagnostics"
echo "================================================================================"

echo ""
echo "=== Platform APIs (Required) ==="
echo "EventDrivenService XRD:"
kubectl get xrd xeventdrivenservices.platform.bizmatters.io 2>/dev/null && echo "  ✓ Available" || echo "  ✗ Missing"
echo "PostgresInstance XRD:"
kubectl get xrd xpostgresinstances.database.bizmatters.io 2>/dev/null && echo "  ✓ Available" || echo "  ✗ Missing"
echo "DragonflyInstance XRD:"
kubectl get xrd xdragonflyinstances.database.bizmatters.io 2>/dev/null && echo "  ✓ Available" || echo "  ✗ Missing"

echo ""
echo "=== Database Claims ==="
echo "PostgreSQL Claim:"
kubectl get postgresinstance deepagents-runtime-db -n intelligence-deepagents -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True" && echo "  ✓ Ready" || echo "  ⏳ Not ready"
echo "Dragonfly Claim:"
kubectl get dragonflyinstance deepagents-runtime-cache -n intelligence-deepagents -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True" && echo "  ✓ Ready" || echo "  ⏳ Not ready"

echo ""
echo "=== Database Pods ==="
echo "PostgreSQL:"
kubectl get pods -n intelligence-deepagents -l postgresql=deepagents-runtime-db -o wide 2>/dev/null || echo "  No pods found"
echo ""
echo "Dragonfly:"
kubectl get pods -n intelligence-deepagents -l app.kubernetes.io/name=deepagents-runtime-cache -o wide 2>/dev/null || echo "  No pods found"

echo ""
echo "=== Connection Secrets ==="
echo "PostgreSQL Connection Secret:"
kubectl get secret deepagents-runtime-db-conn -n intelligence-deepagents 2>/dev/null && echo "  ✓ Exists" || echo "  ✗ Missing"
echo "Dragonfly Connection Secret:"
kubectl get secret deepagents-runtime-cache-conn -n intelligence-deepagents 2>/dev/null && echo "  ✓ Exists" || echo "  ✗ Missing"
echo "LLM Keys Secret:"
kubectl get secret deepagents-runtime-llm-keys -n intelligence-deepagents 2>/dev/null && echo "  ✓ Exists" || echo "  ✗ Missing"

echo ""
echo "=== NATS Messaging ==="
kubectl get pods -n nats -l app.kubernetes.io/name=nats -o wide 2>/dev/null || echo "  No NATS pods found"

echo ""
echo "=== Namespace Resource Usage ==="
kubectl top pods -n intelligence-deepagents 2>/dev/null || echo "  Metrics not available"

echo ""
echo "=== Recent Events (intelligence-deepagents namespace) ==="
kubectl get events -n intelligence-deepagents --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo "  No events found"

echo ""
echo "================================================================================"
echo "Diagnostics complete"
echo "================================================================================"
