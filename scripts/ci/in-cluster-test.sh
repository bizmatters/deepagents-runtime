#!/bin/bash
set -euo pipefail

# ==============================================================================
# Centralized In-Cluster Testing Framework
# ==============================================================================
# Purpose: Reusable script for running any test suite in Kubernetes cluster
# Usage: ./scripts/ci/in-cluster-test.sh <test_path> [test_name] [timeout]
# Examples:
#   ./scripts/ci/in-cluster-test.sh tests/integration/test_nats_events_integration.py
#   ./scripts/ci/in-cluster-test.sh tests/integration/test_agent_generation_workflow.py agent-generation 900
# ==============================================================================

# Parameters
TEST_PATH="${1:-tests/integration}"
TEST_NAME="${2:-integration-tests}"
TIMEOUT="${3:-600}"
NAMESPACE="${NAMESPACE:-intelligence-deepagents}"
IMAGE="${IMAGE:-deepagents-runtime:ci-test}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }

# Validate inputs
if [[ -z "$TEST_PATH" ]]; then
    log_error "Test path is required"
    echo "Usage: $0 <test_path> [test_name] [timeout]"
    exit 1
fi

log_info "Starting in-cluster test execution"
log_info "Test Path: $TEST_PATH"
log_info "Test Name: $TEST_NAME"
log_info "Timeout: ${TIMEOUT}s"
log_info "Namespace: $NAMESPACE"
log_info "Image: $IMAGE"

# Generate unique job name
JOB_NAME="${TEST_NAME}-$(date +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create test job from template
create_test_job() {
    local job_file="/tmp/${JOB_NAME}.yaml"
    
    log_info "Creating test job: $JOB_NAME"
    
    cat > "$job_file" << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    app: deepagents-runtime-tests
    test-type: integration
    test-suite: $TEST_NAME
spec:
  template:
    metadata:
      labels:
        app: deepagents-runtime-tests
        test-type: integration
        test-suite: $TEST_NAME
    spec:
      containers:
      - name: test-runner
        image: $IMAGE
        workingDir: /app
        env:
        # Database credentials from K8s secrets
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-db-conn
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-db-conn
              key: POSTGRES_PASSWORD
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-db-conn
              key: POSTGRES_DB
        # Cache credentials
        - name: DRAGONFLY_PASSWORD
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-cache-conn
              key: DRAGONFLY_PASSWORD
        # In-cluster service DNS names for tests
        - name: TEST_POSTGRES_HOST
          value: "deepagents-runtime-db-rw"
        - name: TEST_POSTGRES_PORT
          value: "5432"
        - name: TEST_REDIS_HOST
          value: "deepagents-runtime-cache"
        - name: TEST_REDIS_PORT
          value: "6379"
        - name: TEST_NATS_URL
          value: "nats://nats.nats.svc:4222"
        # Standard app environment variables for in-cluster
        - name: POSTGRES_HOST
          value: "deepagents-runtime-db-rw"
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_SCHEMA
          value: "public"
        - name: DRAGONFLY_HOST
          value: "deepagents-runtime-cache"
        - name: DRAGONFLY_PORT
          value: "6379"
        - name: NATS_URL
          value: "nats://nats.nats.svc:4222"
        # Test configuration
        - name: USE_MOCK_LLM
          value: "${USE_MOCK_LLM:-true}"
        - name: MOCK_TIMEOUT
          value: "${MOCK_TIMEOUT:-60}"
        - name: REAL_TIMEOUT
          value: "${REAL_TIMEOUT:-480}"
        # LLM API keys
        - name: OPENAI_API_KEY
          value: "${OPENAI_API_KEY:-mock-key-for-testing}"
        - name: ANTHROPIC_API_KEY
          value: "${ANTHROPIC_API_KEY:-mock-key-for-testing}"
        command: 
        - "/bin/bash"
        - "-c"
        - |
          echo "Starting in-cluster integration tests..."
          echo "Test Path: $TEST_PATH"
          echo "Python version: \$(python --version)"
          
          # Install required packages for database operations and health checks
          echo "Installing required packages..."
          apt-get update -qq && apt-get install -y -qq postgresql-client curl
          
          # Run database migrations first
          echo "Running database migrations..."
          export POSTGRES_HOST=deepagents-runtime-db-rw
          export POSTGRES_PORT=5432
          export POSTGRES_SCHEMA=public
          export MIGRATION_DIR=./migrations
          
          # Wait for database to be ready
          echo "Waiting for database to be ready..."
          until pg_isready -h \$POSTGRES_HOST -p \$POSTGRES_PORT -U \$POSTGRES_USER; do 
            echo "Database not ready, waiting..."
            sleep 2
          done
          echo "Database is ready"
          
          # Run migrations
          chmod +x scripts/ci/run-migrations.sh
          ./scripts/ci/run-migrations.sh
          echo "Database migrations completed"
          
          # Start FastAPI application in background
          echo "Starting FastAPI application..."
          python -m uvicorn api.main:app --host 0.0.0.0 --port 8000 &
          APP_PID=\$!
          
          # Wait for app to start
          echo "Waiting for FastAPI to be ready..."
          timeout 60 bash -c 'until curl -f http://localhost:8000/health; do sleep 2; done'
          echo "FastAPI application started successfully"
          
          echo "Checking installed packages..."
          pip list | grep -E "(pytest|deepagents)"
          echo "Running tests..."
          python -m pytest "$TEST_PATH" \\
            -v \\
            --tb=short \\
            --timeout=300 \\
            --junit-xml=artifacts/test-results.xml \\
            --cov=. \\
            --cov-report=xml:artifacts/coverage.xml \\
            --cov-report=html:artifacts/htmlcov
          
          # Stop FastAPI application
          if [ ! -z "\$APP_PID" ]; then
            kill \$APP_PID || true
          fi
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "250m"
        volumeMounts:
        - name: artifacts
          mountPath: /app/artifacts
      volumes:
      - name: artifacts
        emptyDir: {}
      restartPolicy: Never
      serviceAccountName: default
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
EOF

    echo "$job_file"
}

# Deploy and monitor test job
run_test_job() {
    local job_file="$1"
    
    # Clean up any existing job
    kubectl delete job "$JOB_NAME" -n "$NAMESPACE" 2>/dev/null || true
    
    # Deploy test job
    log_info "Deploying in-cluster test job..."
    kubectl apply -f "$job_file"
    
    # Monitor job progress
    log_info "Waiting for test job to complete..."
    local elapsed=0
    local status=""
    local pod_name=""
    
    while [[ $elapsed -lt $TIMEOUT ]]; do
        # Get job status
        status=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Pending")
        
        # Get pod info
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$pod_name" ]]; then
            pod_status=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            pod_ready=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        else
            pod_status="Pending"
            pod_ready="false"
        fi
        
        log_info "[${elapsed}s/${TIMEOUT}s] Job: $status, Pod: $pod_status, Ready: $pod_ready"
        
        # Show recent logs if pod is running
        if [[ "$pod_status" == "Running" && -n "$pod_name" ]]; then
            log_info "Recent logs:"
            kubectl logs "$pod_name" -n "$NAMESPACE" --tail=5 2>/dev/null | sed 's/^/  /' || true
        fi
        
        # Check if job completed
        if [[ "$status" == "Complete" ]]; then
            log_success "Test job completed successfully"
            return 0
        elif [[ "$status" == "Failed" ]]; then
            log_error "Test job failed"
            return 1
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    log_error "Test job timed out after ${TIMEOUT}s"
    return 1
}

# Copy artifacts from completed pod
copy_artifacts() {
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$pod_name" ]]; then
        log_info "Copying artifacts from pod: $pod_name"
        
        # Create local artifacts directory
        mkdir -p artifacts
        
        # Copy test results and coverage
        kubectl cp "$NAMESPACE/$pod_name:/app/artifacts/test-results.xml" "./artifacts/test-results.xml" 2>/dev/null || log_warn "No test-results.xml to copy"
        kubectl cp "$NAMESPACE/$pod_name:/app/artifacts/coverage.xml" "./artifacts/coverage.xml" 2>/dev/null || log_warn "No coverage.xml to copy"
        
        # Copy HTML coverage report
        kubectl cp "$NAMESPACE/$pod_name:/app/artifacts/htmlcov" "./artifacts/htmlcov" 2>/dev/null || log_warn "No htmlcov directory to copy"
        
        log_info "Artifacts copied to ./artifacts/"
    else
        log_warn "No pod found to copy artifacts from"
    fi
}

# Get final test results
get_test_results() {
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$pod_name" ]]; then
        log_info "Getting test results..."
        kubectl logs "$pod_name" -n "$NAMESPACE" | tail -50
    fi
}

# Enhanced error handling
error_handler() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line $line_number with exit code $exit_code"
    log_error "Last command: $BASH_COMMAND"
    
    # Get pod logs for debugging
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$pod_name" ]]; then
        log_error "Pod logs for debugging:"
        kubectl logs "$pod_name" -n "$NAMESPACE" --tail=50 2>/dev/null || true
    fi
    
    return $exit_code
}

trap 'error_handler $LINENO' ERR

# Cleanup function
cleanup() {
    log_info "Cleaning up test job: $JOB_NAME"
    kubectl delete job "$JOB_NAME" -n "$NAMESPACE" 2>/dev/null || true
    rm -f "/tmp/${JOB_NAME}.yaml" 2>/dev/null || true
}

# Main execution
main() {
    # Create test job
    job_file=$(create_test_job)
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    # Run the test
    if run_test_job "$job_file"; then
        copy_artifacts
        get_test_results
        log_success "In-cluster tests completed successfully"
        exit 0
    else
        copy_artifacts
        get_test_results
        log_error "In-cluster tests failed"
        exit 1
    fi
}

# Execute main function
main "$@"