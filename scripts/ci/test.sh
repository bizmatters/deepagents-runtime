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

# Validate required environment variables (skip if using mock mode)
if [ "${USE_MOCK_LLM:-false}" != "true" ]; then
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
else
    log_info "🤖 Running in mock mode - skipping API key validation"
    export OPENAI_API_KEY="mock-key-for-testing"
fi

# Optional: ANTHROPIC_API_KEY (warn if missing)
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    log_info "⚠️  ANTHROPIC_API_KEY not set - Anthropic tests will be skipped"
fi

# Run integration tests against deployed K8s services
if [[ "${TEST_DIR}" == *"integration"* ]]; then
    log_info "Setting up port-forwards to K8s services..."
    
    NAMESPACE="intelligence-deepagents"
    
    # Get database credentials from K8s secret
    DB_USER=$(kubectl get secret -n $NAMESPACE deepagents-runtime-db-conn -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
    DB_PASS=$(kubectl get secret -n $NAMESPACE deepagents-runtime-db-conn -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
    DB_NAME=$(kubectl get secret -n $NAMESPACE deepagents-runtime-db-conn -o jsonpath='{.data.POSTGRES_DB}' | base64 -d)
    
    # Get Dragonfly password from K8s secret
    REDIS_PASS=$(kubectl get secret -n $NAMESPACE deepagents-runtime-cache-conn -o jsonpath='{.data.DRAGONFLY_PASSWORD}' | base64 -d)
    
    log_info "Database: ${DB_NAME} (user: ${DB_USER})"
    log_info "Cache: Dragonfly (authenticated with password)"
    
    # Function to start a robust port-forward with enhanced logging
    start_port_forward() {
        local namespace=$1
        local service=$2
        local local_port=$3
        local remote_port=$4
        local name=$5
        
        log_info "Starting port-forward for $name ($local_port -> $remote_port)..."
        
        # Kill any existing process on the port
        local existing_pids=$(lsof -ti:$local_port 2>/dev/null || true)
        if [ ! -z "$existing_pids" ]; then
            log_info "  Killing existing processes on port $local_port: $existing_pids"
            echo "$existing_pids" | xargs kill -9 2>/dev/null || true
        fi
        sleep 1
        
        # Check if service exists and is ready
        local service_name=${service#svc/}  # Remove svc/ prefix if present
        log_info "  Checking service availability: $service_name in namespace $namespace"
        if ! kubectl get service -n $namespace $service_name >/dev/null 2>&1; then
            log_error "  Service $service_name not found in namespace $namespace"
            return 1
        fi
        
        # Start port-forward with retry logic
        local max_attempts=3
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            log_info "  Attempt $attempt/$max_attempts for $name..."
            
            # Start port-forward
            kubectl port-forward -n $namespace $service $local_port:$remote_port >/dev/null 2>&1 &
            local pid=$!
            
            log_info "  Started kubectl port-forward (PID: $pid)"
            
            # Wait and test the connection
            sleep 5
            
            # Check if process is still running
            if ! kill -0 $pid 2>/dev/null; then
                log_error "  Port-forward process $pid died immediately"
                ((attempt++))
                continue
            fi
            
            # Test connection
            if nc -z localhost $local_port 2>/dev/null; then
                log_info "  ✅ $name port-forward successful (PID: $pid)"
                echo $pid
                return 0
            else
                log_error "  ❌ $name port-forward connection test failed"
                kill $pid 2>/dev/null || true
                sleep 2
            fi
            
            ((attempt++))
        done
        
        log_error "Failed to establish $name port-forward after $max_attempts attempts"
        return 1
    }
    
    # Start port-forwards with robust error handling
    PF_PG_PID=$(start_port_forward "$NAMESPACE" "svc/deepagents-runtime-db-rw" "15433" "5432" "PostgreSQL")
    if [ $? -ne 0 ]; then
        log_error "Failed to start PostgreSQL port-forward"
        exit 1
    fi
    
    PF_REDIS_PID=$(start_port_forward "$NAMESPACE" "svc/deepagents-runtime-cache" "16380" "6379" "Redis/Dragonfly")
    if [ $? -ne 0 ]; then
        log_error "Failed to start Redis port-forward"
        kill $PF_PG_PID 2>/dev/null || true
        exit 1
    fi
    
    PF_NATS_PID=$(start_port_forward "nats" "svc/nats" "14222" "4222" "NATS")
    if [ $? -ne 0 ]; then
        log_error "Failed to start NATS port-forward"
        kill $PF_PG_PID $PF_REDIS_PID 2>/dev/null || true
        exit 1
    fi
    
    # Enhanced cleanup function with detailed logging
    cleanup_port_forwards() {
        log_info "Cleaning up port-forwards..."
        
        # Check status of port-forward processes before cleanup
        for pid in $PF_PG_PID $PF_REDIS_PID $PF_NATS_PID; do
            if [ ! -z "$pid" ]; then
                if kill -0 $pid 2>/dev/null; then
                    log_info "  Port-forward PID $pid is still running"
                else
                    log_error "  Port-forward PID $pid has already died"
                fi
                kill $pid 2>/dev/null || true
            fi
        done
        
        # Kill any remaining processes on our ports
        for port in 15433 16380 14222; do
            local remaining_pids=$(lsof -ti:$port 2>/dev/null || true)
            if [ ! -z "$remaining_pids" ]; then
                log_info "  Cleaning up remaining processes on port $port: $remaining_pids"
                echo "$remaining_pids" | xargs kill -9 2>/dev/null || true
            fi
        done
        
        # Collect port-forward logs for debugging
        log_info "Port-forward logs collected in ${ARTIFACTS_DIR}/"
        ls -la "${ARTIFACTS_DIR}"/port-forward-*.log 2>/dev/null || log_info "  No port-forward logs found"
        
        sleep 2
    }
    trap cleanup_port_forwards EXIT
    
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

# Run tests with port-forward monitoring
log_info "Executing pytest tests on ${TEST_DIR}..."
cd "${REPO_ROOT}"

# Use the provided test directory/file path directly
TEST_PATH="${TEST_DIR}"

# Check port-forward health before starting tests (for integration tests only)
if [[ "${TEST_DIR}" == *"integration"* ]]; then
    log_info "Final port-forward health check before tests..."
    for port_name_pid in "PostgreSQL:15433:$PF_PG_PID" "Redis:16380:$PF_REDIS_PID" "NATS:14222:$PF_NATS_PID"; do
        IFS=':' read -r name port pid <<< "$port_name_pid"
        
        if [ ! -z "$pid" ]; then
            if kill -0 $pid 2>/dev/null; then
                if nc -z localhost $port 2>/dev/null; then
                    log_info "  ✅ $name port-forward (PID: $pid) ready"
                else
                    log_error "  ⚠️  $name port-forward (PID: $pid) process alive but port $port not responding"
                fi
            else
                log_error "  ❌ $name port-forward (PID: $pid) process died"
            fi
        fi
    done
fi

python -m pytest "${TEST_PATH}" \
    -v \
    --tb=short \
    --timeout=300 \
    --junit-xml="${ARTIFACTS_DIR}/test-results.xml" \
    --cov=. \
    --cov-report=xml:"${ARTIFACTS_DIR}/coverage.xml" \
    --cov-report=html:"${ARTIFACTS_DIR}/htmlcov"

EXIT_CODE=$?

# Check port-forward status after tests (for integration tests only)
if [[ "${TEST_DIR}" == *"integration"* ]]; then
    log_info "Post-test port-forward status check..."
    for port_name_pid in "PostgreSQL:15433:$PF_PG_PID" "Redis:16380:$PF_REDIS_PID" "NATS:14222:$PF_NATS_PID"; do
        IFS=':' read -r name port pid <<< "$port_name_pid"
        
        if [ ! -z "$pid" ]; then
            if kill -0 $pid 2>/dev/null; then
                log_info "  ✅ $name port-forward (PID: $pid) still running"
            else
                log_error "  ❌ $name port-forward (PID: $pid) died during tests"
                
                # Show the log tail for debugging
                name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '/' '-')
                pf_log="${ARTIFACTS_DIR}/port-forward-${name_lower}-${port}.log"
                if [ -f "$pf_log" ]; then
                    log_error "  Last 10 lines of $name port-forward log:"
                    tail -10 "$pf_log" | sed 's/^/    /'
                fi
            fi
        fi
    done
fi

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