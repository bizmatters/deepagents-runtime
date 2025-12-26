#!/bin/bash
set -euo pipefail

# ==============================================================================
# Tier 2 Local Script: Run Tests Locally
# ==============================================================================
# Purpose: Execute test suite (unit, integration, or both) in local environment
# Called by: Developer via terminal
# Usage: ./scripts/local/test.sh [test_directory]
#        ./scripts/local/test.sh                    # Run both unit and integration
#        ./scripts/local/test.sh tests/unit         # Run only unit tests
#        ./scripts/local/test.sh tests/integration  # Run only integration tests
# ==============================================================================

TEST_DIR="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -n "${TEST_DIR}" ]; then
    echo "================================================================================"
    echo "Running Agent Executor Tests (Local Mode)"
    echo "================================================================================"
    echo "  Test Directory:    ${TEST_DIR}"
    echo "================================================================================"
else
    echo "================================================================================"
    echo "Running Agent Executor Test Suite (Local Mode)"
    echo "================================================================================"
    echo "  Test Types:        Unit + Integration"
    echo "================================================================================"
fi

# Set test environment variables
export TESTING=true
export LOG_LEVEL="${LOG_LEVEL:-info}"

if [ -n "${TEST_DIR}" ]; then
    # Run specific test directory
    echo ""
    echo "→ Running tests in ${TEST_DIR}..."
    
    # Start test infrastructure if running integration tests
    if [[ "${TEST_DIR}" == *"integration"* ]] && [ -f "tests/integration/docker-compose.test.yml" ]; then
        echo "→ Starting test infrastructure..."
        docker-compose -f tests/integration/docker-compose.test.yml up -d
        echo "→ Waiting for services to be ready..."
        sleep 10
        
        # Run database migrations
        echo "→ Running database migrations..."
        export POSTGRES_HOST="localhost"
        export POSTGRES_PORT="15433"
        export POSTGRES_DB="test_db"
        export POSTGRES_USER="test_user"
        export POSTGRES_PASSWORD="test_pass"
        export POSTGRES_SCHEMA="public"
        
        for migration in migrations/*.up.sql; do
            if [ -f "$migration" ]; then
                echo "Applying migration: $(basename "$migration")"
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
        echo "✅ Migrations completed successfully"
    fi
    
    # Run tests
    poetry run pytest "${TEST_DIR}" \
        -v \
        --color=yes \
        --tb=short \
        --cov=. \
        --cov-report=term-missing \
        --cov-report=html
    
    EXIT_CODE=$?
    
    # Clean up test infrastructure if it was started
    if [[ "${TEST_DIR}" == *"integration"* ]] && [ -f "tests/integration/docker-compose.test.yml" ]; then
        echo "→ Stopping test infrastructure..."
        docker-compose -f tests/integration/docker-compose.test.yml down -v
    fi
    
    if [ ${EXIT_CODE} -eq 0 ]; then
        echo -e "${GREEN}✅ Tests passed: ${TEST_DIR}${NC}"
        echo "Coverage report available at: ${REPO_ROOT}/htmlcov/index.html"
    else
        echo -e "${RED}❌ Tests failed: ${TEST_DIR}${NC}"
    fi
    
    exit ${EXIT_CODE}
else
    # Run both unit and integration tests (original behavior)
    # Track test results
    UNIT_EXIT_CODE=0
    INTEGRATION_EXIT_CODE=0

    # Stage 1: Unit Tests
    echo ""
    echo "================================================================================"
    echo "Stage 1: Unit Tests"
    echo "================================================================================"

    if [ -d "tests/unit" ]; then
        poetry run pytest tests/unit/ \
            -v \
            --color=yes \
            --tb=short \
            --cov=. \
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

    # Stage 2: Integration Tests
    echo ""
    echo "================================================================================"
    echo "Stage 2: Integration Tests"
    echo "================================================================================"

    if [ -d "tests/integration" ]; then
        # Start test infrastructure
        if [ -f "tests/integration/docker-compose.test.yml" ]; then
            echo "→ Starting test infrastructure..."
            docker-compose -f tests/integration/docker-compose.test.yml up -d
            echo "→ Waiting for services to be ready..."
            sleep 10
            
            # Run database migrations
            echo "→ Running database migrations..."
            export POSTGRES_HOST="localhost"
            export POSTGRES_PORT="15433"
            export POSTGRES_DB="test_db"
            export POSTGRES_USER="test_user"
            export POSTGRES_PASSWORD="test_pass"
            export POSTGRES_SCHEMA="public"
            
            for migration in migrations/*.up.sql; do
                if [ -f "$migration" ]; then
                    echo "Applying migration: $(basename "$migration")"
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
            echo "✅ Migrations completed successfully"
        fi

        # Run integration tests
        poetry run pytest tests/integration/ \
            -v \
            --color=yes \
            --tb=short \
            || INTEGRATION_EXIT_CODE=$?

        # Clean up test infrastructure
        if [ -f "tests/integration/docker-compose.test.yml" ]; then
            echo "→ Stopping test infrastructure..."
            docker-compose -f tests/integration/docker-compose.test.yml down -v
        fi

        if [ ${INTEGRATION_EXIT_CODE} -eq 0 ]; then
            echo -e "${GREEN}✅ Integration tests passed${NC}"
        else
            echo -e "${RED}❌ Integration tests failed${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  No integration tests found (tests/integration/ does not exist)${NC}"
    fi

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
        echo "Coverage report available at: ${REPO_ROOT}/htmlcov/index.html"
        exit 0
    else
        echo -e "${RED}❌ Some tests failed${NC}"
        [ ${UNIT_EXIT_CODE} -ne 0 ] && echo "  - Unit tests: FAIL"
        [ ${INTEGRATION_EXIT_CODE} -ne 0 ] && echo "  - Integration tests: FAIL"
        exit 1
    fi
fi