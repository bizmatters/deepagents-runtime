#!/bin/bash
set -e

# ==============================================================================
# Tier 3 CI Script: Run Integration Tests
# ==============================================================================
# Purpose: Execute integration tests with docker-compose infrastructure
# Owner: Backend Developer
# Called by: Tier 2 orchestration scripts (scripts/ci/run-integration-tests.sh)
#
# Environment Variables (CI-provided):
#   - OPENAI_API_KEY: OpenAI API key (required)
#
# Assumptions:
#   - Docker and docker-compose installed (pre-installed on GitHub Actions runners)
#   - Test dependencies installed (via Tier 2 script)
#   - Working directory is services/agent_executor/
# ==============================================================================

echo "================================================================================"
echo "Running Agent Executor Integration Tests (CI Mode)"
echo "================================================================================"

# Validate required environment variables
REQUIRED_VARS=("OPENAI_API_KEY")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo "❌ ERROR: Missing required environment variables:"
    printf '  - %s\n' "${MISSING_VARS[@]}"
    exit 1
fi

# Step 1: Start test infrastructure using docker-compose
echo ""
echo "→ Starting test infrastructure (PostgreSQL, Dragonfly, NATS)..."
echo ""

docker-compose -f tests/integration/docker-compose.test.yml up -d

# Wait for services to be healthy
echo "Waiting for services to be healthy..."
sleep 10

# Verify services are running
docker-compose -f tests/integration/docker-compose.test.yml ps

# Step 2: Run database migrations
echo ""
echo "→ Running database migrations..."
echo ""

export POSTGRES_HOST="localhost"
export POSTGRES_PORT="15433"
export POSTGRES_DB="test_db"
export POSTGRES_USER="test_user"
export POSTGRES_PASSWORD="test_pass"
export POSTGRES_SCHEMA="public"

for migration in migrations/*.up.sql; do
    echo "Applying migration: $(basename "$migration")"
    PGPASSWORD="$POSTGRES_PASSWORD" psql \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        -v ON_ERROR_STOP=1 \
        -c "SET search_path TO ${POSTGRES_SCHEMA};" \
        -f "$migration"
done

echo "✅ Migrations completed successfully"

# Step 3: Run integration tests
echo ""
echo "→ Executing integration tests..."
echo ""

# Set test environment variables
export POSTGRES_HOST="localhost"
export POSTGRES_PORT="15433"
export POSTGRES_DB="test_db"
export POSTGRES_USER="test_user"
export POSTGRES_PASSWORD="test_pass"
export POSTGRES_SCHEMA="public"
export DRAGONFLY_HOST="localhost"
export DRAGONFLY_PORT="16380"
export NATS_URL="nats://localhost:14222"
export DISABLE_VAULT_AUTH="true"
export TESTING="true"

TESTS_PATH="tests/integration/test_api.py"

if [ ! -f "${TESTS_PATH}" ]; then
    echo "❌ ERROR: Integration test file not found at ${TESTS_PATH}"
    docker-compose -f tests/integration/docker-compose.test.yml down -v
    exit 1
fi

# Run pytest with verbose output, coverage, and test results
pytest "${TESTS_PATH}" \
    -v \
    -s \
    --tb=short \
    --timeout=300 \
    --junit-xml=test-results.xml \
    --cov=agent_executor \
    --cov-report=xml \
    --cov-report=html

# Capture exit code
EXIT_CODE=$?

# Step 4: Cleanup - Stop and remove containers
echo ""
echo "→ Cleaning up test infrastructure..."
echo ""

docker-compose -f tests/integration/docker-compose.test.yml down -v

echo ""
if [ ${EXIT_CODE} -eq 0 ]; then
    echo "✅ Integration tests passed successfully"
else
    echo "❌ Integration tests failed with exit code ${EXIT_CODE}"
fi
echo "================================================================================"

exit ${EXIT_CODE}
