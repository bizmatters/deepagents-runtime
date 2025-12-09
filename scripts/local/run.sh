#!/bin/bash
set -e

# ==============================================================================
# Tier 3 Local Script: Development Entrypoint
# ==============================================================================
# Purpose: Start agent-executor service in local development mode with hot-reload
# Owner: Backend Developer
# Called by: Developer via terminal
#
# Features:
#   - Hot-reloading for code changes
#   - Local environment variable setup
#   - Optional Docker Compose for dependencies
#   - Poetry-managed virtual environment
#
# Environment:
#   - Uses .env file if present
#   - Defaults to localhost infrastructure
#   - NEVER called by CI
# ==============================================================================

# Navigate to service directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${SERVICE_DIR}"

echo "================================================================================"
echo "Starting Agent Executor Service (Local Development Mode)"
echo "================================================================================"
echo "  Service Directory: ${SERVICE_DIR}"
echo "  Hot-reload:        Enabled"
echo "  Port:              8080"
echo "================================================================================"

# Load environment variables from .env if present
if [ -f ".env" ]; then
    echo "→ Loading environment from .env file..."
    set -a
    source .env
    set +a
fi

# Set default local environment variables
export PORT="${PORT:-8080}"
export LOG_LEVEL="${LOG_LEVEL:-debug}"
export VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"

# Optional: Start local infrastructure with Docker Compose
# Uncomment if you have a docker-compose.yml for local dependencies
# if [ -f "docker-compose.local.yml" ]; then
#     echo "→ Starting local infrastructure (PostgreSQL, Redis, NATS)..."
#     docker-compose -f docker-compose.local.yml up -d
#     echo "→ Waiting for services to be ready..."
#     sleep 5
# fi

echo ""
echo "→ Starting service with hot-reload..."
echo "→ Access the service at: http://localhost:${PORT}"
echo "→ API docs available at: http://localhost:${PORT}/docs"
echo ""

# Start with Poetry in development mode
# - Uvicorn --reload watches for file changes
# - Uses Poetry-managed virtual environment
poetry run uvicorn agent_executor.api.main:app \
    --reload \
    --host 0.0.0.0 \
    --port "${PORT}" \
    --log-level "${LOG_LEVEL}"
