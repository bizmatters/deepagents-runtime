#!/bin/bash
set -euo pipefail

# ==============================================================================
# Local Script: Run Integration Tests Against Deployed K8s Environment
# ==============================================================================
# Purpose: Execute integration tests against real K8s services via port-forwards
# Usage: ./scripts/local/test-k8s.sh [pytest-args]
#        ./scripts/local/test-k8s.sh                           # Run all integration tests
#        ./scripts/local/test-k8s.sh -k test_cloudevent        # Run specific test
#        ./scripts/local/test-k8s.sh -v -s                     # Verbose with stdout
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE_DEEPAGENTS="intelligence-deepagents"
NAMESPACE_NATS="nats"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "================================================================================"
echo "Running Integration Tests Against K8s Environment"
echo "================================================================================"

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi

# Get database credentials from K8s secret
echo -e "${YELLOW}→ Fetching database credentials from K8s...${NC}"
DB_USER=$(kubectl get secret -n $NAMESPACE_DEEPAGENTS deepagents-runtime-db-app -o jsonpath='{.data.username}' | base64 -d)
DB_PASS=$(kubectl get secret -n $NAMESPACE_DEEPAGENTS deepagents-runtime-db-app -o jsonpath='{.data.password}' | base64 -d)
DB_NAME=$(kubectl get secret -n $NAMESPACE_DEEPAGENTS deepagents-runtime-db-app -o jsonpath='{.data.dbname}' | base64 -d 2>/dev/null || echo "deepagents-runtime-db")

echo -e "${GREEN}  Database: ${DB_NAME} (user: ${DB_USER})${NC}"

# Kill any existing port-forwards on our ports
echo -e "${YELLOW}→ Cleaning up existing port-forwards...${NC}"
pkill -f "kubectl port-forward.*15433:5432" 2>/dev/null || true
pkill -f "kubectl port-forward.*16380:6379" 2>/dev/null || true
pkill -f "kubectl port-forward.*14222:4222" 2>/dev/null || true
sleep 2

# Start port-forwards in background
echo -e "${YELLOW}→ Starting port-forwards...${NC}"

kubectl port-forward -n $NAMESPACE_DEEPAGENTS svc/deepagents-runtime-db-rw 15433:5432 &>/dev/null &
PF_PG_PID=$!

kubectl port-forward -n $NAMESPACE_DEEPAGENTS svc/deepagents-runtime-cache 16380:6379 &>/dev/null &
PF_REDIS_PID=$!

kubectl port-forward -n $NAMESPACE_NATS svc/nats 14222:4222 &>/dev/null &
PF_NATS_PID=$!

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}→ Cleaning up port-forwards...${NC}"
    kill $PF_PG_PID 2>/dev/null || true
    kill $PF_REDIS_PID 2>/dev/null || true
    kill $PF_NATS_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for port-forwards to be ready
echo -e "${YELLOW}→ Waiting for port-forwards...${NC}"
sleep 3

# Verify connections
READY=true
if nc -z localhost 15433 2>/dev/null; then
    echo -e "${GREEN}  ✓ PostgreSQL (15433)${NC}"
else
    echo -e "${RED}  ✗ PostgreSQL (15433)${NC}"
    READY=false
fi

if nc -z localhost 16380 2>/dev/null; then
    echo -e "${GREEN}  ✓ Redis/Dragonfly (16380)${NC}"
else
    echo -e "${RED}  ✗ Redis/Dragonfly (16380)${NC}"
    READY=false
fi

if nc -z localhost 14222 2>/dev/null; then
    echo -e "${GREEN}  ✓ NATS (14222)${NC}"
else
    echo -e "${RED}  ✗ NATS (14222)${NC}"
    READY=false
fi

if [ "$READY" = false ]; then
    echo -e "${RED}Error: Not all services are reachable${NC}"
    exit 1
fi

# Export environment variables for tests
export TEST_POSTGRES_HOST="localhost"
export TEST_POSTGRES_PORT="15433"
export TEST_POSTGRES_USER="$DB_USER"
export TEST_POSTGRES_PASSWORD="$DB_PASS"
export TEST_POSTGRES_DB="$DB_NAME"
export TEST_REDIS_HOST="localhost"
export TEST_REDIS_PORT="16380"
export TEST_NATS_URL="nats://localhost:14222"

# Also set standard env vars used by the app
export POSTGRES_HOST="localhost"
export POSTGRES_PORT="15433"
export POSTGRES_USER="$DB_USER"
export POSTGRES_PASSWORD="$DB_PASS"
export POSTGRES_DB="$DB_NAME"
export POSTGRES_SCHEMA="public"
export DRAGONFLY_HOST="localhost"
export DRAGONFLY_PORT="16380"
export NATS_URL="nats://localhost:14222"
export DISABLE_VAULT_AUTH="true"
export TESTING="true"

echo ""
echo "================================================================================"
echo -e "${GREEN}Environment ready - running tests${NC}"
echo "================================================================================"
echo ""

# Run pytest
python -m pytest tests/integration/test_api.py \
    -v \
    --color=yes \
    --tb=short \
    --timeout=120 \
    "$@"

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}================================================================================${NC}"
    echo -e "${GREEN}All tests passed!${NC}"
    echo -e "${GREEN}================================================================================${NC}"
else
    echo -e "${RED}================================================================================${NC}"
    echo -e "${RED}Tests failed (exit code: $EXIT_CODE)${NC}"
    echo -e "${RED}================================================================================${NC}"
fi

exit $EXIT_CODE
