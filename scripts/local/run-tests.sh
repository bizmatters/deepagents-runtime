#!/bin/bash
set -e

# ==============================================================================
# Tier 3 Local Script: Run All Tests Locally
# ==============================================================================
# Purpose: Execute complete test suite (unit + integration) in local environment
# Owner: Backend Developer
# Called by: Developer via terminal
#
# Test Stages:
#   1. Unit tests (tests/unit/)
#   2. Integration tests (tests/integration/)
#   3. Optional: Start/stop test containers (PostgreSQL, Redis)
#
# Environment:
#   - Uses local Docker for test dependencies
#   - Poetry-managed virtual environment
#   - Test database isolated from development database
# ==============================================================================

# Navigate to service directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${SERVICE_DIR}"

echo "================================================================================"
echo "Running Agent Executor Test Suite (Local Mode)"
echo "================================================================================"
echo "  Service Directory: ${SERVICE_DIR}"
echo "  Test Types:        Unit + Integration"
echo "================================================================================"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track test results
UNIT_EXIT_CODE=0
INTEGRATION_EXIT_CODE=0

# Optional: Start test infrastructure
# Uncomment if you need PostgreSQL, Redis, etc. for integration tests
# if [ -f "docker-compose.test.yml" ]; then
#     echo "→ Starting test infrastructure..."
#     docker-compose -f docker-compose.test.yml up -d
#     echo "→ Waiting for test services to be ready..."
#     sleep 5
# fi

# Set test environment variables
export TESTING=true
export LOG_LEVEL="${LOG_LEVEL:-info}"
export VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"

echo ""
echo "================================================================================"
echo "Stage 1: Unit Tests"
echo "================================================================================"

if [ -d "tests/unit" ]; then
    poetry run pytest tests/unit/ \
        -v \
        --color=yes \
        --tb=short \
        --cov=agent_executor \
        --cov-report=term-missing \
        --cov-report=html \
        || UNIT_EXIT_CODE=$?

    if [ ${UNIT_EXIT_CODE} -eq 0 ]; then
        echo -e "${GREEN}✅ Unit tests passed${NC}"
    else
        echo -e "${RED}❌ Unit tests failed${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  No unit tests found (tests/unit/ does not exist)${NC}"
fi

echo ""
echo "================================================================================"
echo "Stage 2: Integration Tests"
echo "================================================================================"

if [ -d "tests/integration" ]; then
    poetry run pytest tests/integration/ \
        -v \
        --color=yes \
        --tb=short \
        --timeout=60 \
        || INTEGRATION_EXIT_CODE=$?

    if [ ${INTEGRATION_EXIT_CODE} -eq 0 ]; then
        echo -e "${GREEN}✅ Integration tests passed${NC}"
    else
        echo -e "${RED}❌ Integration tests failed${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  No integration tests found (tests/integration/ does not exist)${NC}"
fi

# Optional: Clean up test infrastructure
# if [ -f "docker-compose.test.yml" ]; then
#     echo ""
#     echo "→ Stopping test infrastructure..."
#     docker-compose -f docker-compose.test.yml down -v
# fi

# Summary
echo ""
echo "================================================================================"
echo "Test Summary"
echo "================================================================================"

if [ ${UNIT_EXIT_CODE} -eq 0 ] && [ ${INTEGRATION_EXIT_CODE} -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed successfully${NC}"
    echo "  - Unit tests: PASS"
    echo "  - Integration tests: PASS"
    echo ""
    echo "Coverage report available at: ${SERVICE_DIR}/htmlcov/index.html"
    echo "================================================================================"
    exit 0
else
    echo -e "${RED}❌ Some tests failed${NC}"
    [ ${UNIT_EXIT_CODE} -ne 0 ] && echo "  - Unit tests: FAIL"
    [ ${INTEGRATION_EXIT_CODE} -ne 0 ] && echo "  - Integration tests: FAIL"
    echo "================================================================================"
    exit 1
fi
