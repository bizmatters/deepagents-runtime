#!/bin/bash
set -euo pipefail

# ==============================================================================
# Tier 2 CI Script: Run Tests
# ==============================================================================
# Purpose: Execute tests (unit or integration) against deployed service
# Called by: GitHub Actions workflow
# Usage: ./scripts/ci/test.sh <test_directory>
# ==============================================================================

TEST_DIR="${1:-tests/integration}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "================================================================================"
echo "Running Tests: ${TEST_DIR}"
echo "================================================================================"

# Create artifacts directory
mkdir -p "${ARTIFACTS_DIR}"

# Validate required environment variables
REQUIRED_VARS=("OPENAI_API_KEY")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
    # Use :- to provide empty default, preventing unbound variable error
    if [ -z "${!var:-}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "Missing required environment variables:"
    printf '  - %s\n' "${MISSING_VARS[@]}"
    exit 1
fi

# Optional: ANTHROPIC_API_KEY (warn if missing)
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    log_info "⚠️  ANTHROPIC_API_KEY not set - Anthropic tests will be skipped"
fi

# Set test environment variables
export DISABLE_VAULT_AUTH="true"

# Run integration tests against deployed K8s services
if [[ "${TEST_DIR}" == *"integration"* ]]; then
    log_info "Setting up port-forwards to K8s services..."
    
    NAMESPACE="intelligence-deepagents"
    
    # Get database credentials from K8s secret
    DB_USER=$(kubectl get secret -n $NAMESPACE deepagents-runtime-db-app -o jsonpath='{.data.username}' | base64 -d)
    DB_PASS=$(kubectl get secret -n $NAMESPACE deepagents-runtime-db-app -o jsonpath='{.data.password}' | base64 -d)
    DB_NAME=$(kubectl get secret -n $NAMESPACE deepagents-runtime-db-app -o jsonpath='{.data.dbname}' | base64 -d 2>/dev/null || echo "deepagents-runtime-db")
    
    # Get Dragonfly password from K8s secret
    REDIS_PASS=$(kubectl get secret -n $NAMESPACE deepagents-runtime-cache-conn -o jsonpath='{.data.DRAGONFLY_PASSWORD}' | base64 -d)
    
    log_info "Database: ${DB_NAME} (user: ${DB_USER})"
    log_info "Cache: Dragonfly (authenticated with password)"
    
    # Start port-forwards in background
    kubectl port-forward -n $NAMESPACE svc/deepagents-runtime-db-rw 15433:5432 &
    PF_PG_PID=$!
    
    kubectl port-forward -n $NAMESPACE svc/deepagents-runtime-cache 16380:6379 &
    PF_REDIS_PID=$!
    
    kubectl port-forward -n nats svc/nats 14222:4222 &
    PF_NATS_PID=$!
    
    # Cleanup function
    cleanup_port_forwards() {
        log_info "Cleaning up port-forwards..."
        kill $PF_PG_PID 2>/dev/null || true
        kill $PF_REDIS_PID 2>/dev/null || true
        kill $PF_NATS_PID 2>/dev/null || true
    }
    trap cleanup_port_forwards EXIT
    
    # Wait for port-forwards to be ready
    sleep 5
    
    # Set environment variables for tests (using TEST_ prefix for fixtures)
    export TEST_POSTGRES_HOST="localhost"
    export TEST_POSTGRES_PORT="15433"
    export TEST_POSTGRES_USER="$DB_USER"
    export TEST_POSTGRES_PASSWORD="$DB_PASS"
    export TEST_POSTGRES_DB="$DB_NAME"
    export TEST_REDIS_HOST="localhost"
    export TEST_REDIS_PORT="16380"
    export TEST_REDIS_PASSWORD="$REDIS_PASS"
    export TEST_NATS_URL="nats://localhost:14222"
    
    # Also set standard env vars for the app
    export POSTGRES_HOST="localhost"
    export POSTGRES_PORT="15433"
    export POSTGRES_USER="$DB_USER"
    export POSTGRES_PASSWORD="$DB_PASS"
    export POSTGRES_DB="$DB_NAME"
    export POSTGRES_SCHEMA="public"
    export DRAGONFLY_HOST="localhost"
    export DRAGONFLY_PORT="16380"
    export DRAGONFLY_PASSWORD="$REDIS_PASS"
    export REDIS_PASSWORD="$REDIS_PASS"
    export NATS_URL="nats://localhost:14222"
    
    # Note: Migrations are already applied by the deployed service's checkpointer
    log_info "✅ Port-forwards ready, using deployed service credentials"
fi

# Run tests
log_info "Executing pytest tests on ${TEST_DIR}..."
cd "${REPO_ROOT}"

python -m pytest "${TEST_DIR}" \
    -v \
    --tb=short \
    --timeout=300 \
    --junit-xml="${ARTIFACTS_DIR}/test-results.xml" \
    --cov=. \
    --cov-report=xml:"${ARTIFACTS_DIR}/coverage.xml" \
    --cov-report=html:"${ARTIFACTS_DIR}/htmlcov"

EXIT_CODE=$?

# Collect debugging artifacts
log_info "Collecting debugging artifacts..."
kubectl get pods --all-namespaces -o wide > "${ARTIFACTS_DIR}/pods.txt" 2>&1 || true
kubectl get scaledobjects --all-namespaces > "${ARTIFACTS_DIR}/keda-scaledobjects.txt" 2>&1 || true
kubectl get postgresinstances,dragonflyinstances,eventdrivenservices --all-namespaces > "${ARTIFACTS_DIR}/crossplane-claims.txt" 2>&1 || true
kubectl logs -n intelligence-deepagents -l app.kubernetes.io/name=deepagents-runtime --tail=1000 > "${ARTIFACTS_DIR}/deepagents-runtime-logs.txt" 2>&1 || true

if [ ${EXIT_CODE} -eq 0 ]; then
    log_success "Tests passed successfully: ${TEST_DIR}"
else
    log_error "Tests failed with exit code ${EXIT_CODE}: ${TEST_DIR}"
fi

exit ${EXIT_CODE}