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
REQUIRED_VARS=("OPENAI_API_KEY" "ANTHROPIC_API_KEY")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "Missing required environment variables:"
    printf '  - %s\n' "${MISSING_VARS[@]}"
    exit 1
fi

# Set test environment variables
export NATS_URL="nats://localhost:14222"
export DISABLE_VAULT_AUTH="true"

# Run database migrations if running integration tests
if [[ "${TEST_DIR}" == *"integration"* ]]; then
    log_info "Running database migrations for integration tests..."
    
    # Set migration environment variables
    export POSTGRES_HOST="localhost"
    export POSTGRES_PORT="15433"
    export POSTGRES_DB="test_db"
    export POSTGRES_USER="test_user"
    export POSTGRES_PASSWORD="test_pass"
    export POSTGRES_SCHEMA="public"
    
    # Apply migrations directly using psql
    for migration in "${REPO_ROOT}/migrations"/*.up.sql; do
        if [ -f "$migration" ]; then
            log_info "Applying migration: $(basename "$migration")"
            PGPASSWORD="$POSTGRES_PASSWORD" psql \
                -h "$POSTGRES_HOST" \
                -p "$POSTGRES_PORT" \
                -U "$POSTGRES_USER" \
                -d "$POSTGRES_DB" \
                -v ON_ERROR_STOP=1 \
                -c "SET search_path TO ${POSTGRES_SCHEMA};" \
                -f "$migration"
        fi
    done
    
    log_info "✅ Migrations completed successfully"
fi

# Run tests
log_info "Executing pytest tests on ${TEST_DIR}..."
cd "${REPO_ROOT}"

python -m pytest "${TEST_DIR}" \
    -v \
    --tb=short \
    --timeout=300 \
    --junit-xml="${ARTIFACTS_DIR}/test-results.xml" \
    --cov=agent_executor \
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