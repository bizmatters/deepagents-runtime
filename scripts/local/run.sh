#!/bin/bash
set -euo pipefail

# ==============================================================================
# Tier 2 Local Script: Start Development Server
# ==============================================================================
# Purpose: Start agent-executor service in local development mode with hot-reload
# Called by: Developer via terminal
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

echo "================================================================================"
echo "Starting Agent Executor Service (Local Development)"
echo "================================================================================"
echo "  Hot-reload:        Enabled"
echo "  Port:              8080"
echo "  API docs:          http://localhost:8080/docs"
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
export DISABLE_VAULT_AUTH="${DISABLE_VAULT_AUTH:-true}"

echo ""
echo "→ Starting service with hot-reload..."
echo "→ Access the service at: http://localhost:${PORT}"
echo "→ API docs available at: http://localhost:${PORT}/docs"
echo ""

# Start with Poetry in development mode
poetry run uvicorn agent_executor.api.main:app \
    --reload \
    --host 0.0.0.0 \
    --port "${PORT}" \
    --log-level "${LOG_LEVEL}"