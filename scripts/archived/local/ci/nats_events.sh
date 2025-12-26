#!/bin/bash
set -euo pipefail

# ==============================================================================
# Local NATS Events Integration Tests Script
# ==============================================================================
# Purpose: Run the same steps as .github/workflows/nats_events.yml locally
# Usage: ./scripts/local/nats_events.sh [--platform-branch <branch>]
#
# Prerequisites:
# 1. .env file with required environment variables
# 2. zerotouch-platform directory exists alongside deepagents-runtime
# 3. Docker, kubectl, and Kind installed
# 4. AWS credentials configured (if not using mocks)
# ==============================================================================

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PLATFORM_DIR="$WORKSPACE_ROOT/zerotouch-platform"
ARTIFACTS_DIR="$REPO_ROOT/artifacts"
LOGS_DIR="$SCRIPT_DIR/logs"

# Default values
PLATFORM_BRANCH="main"
TIMEOUT_MINUTES=45

# Create logs directory and setup logging
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/nats_events_$(date +%Y%m%d_%H%M%S).log"

# Redirect all output to log file while keeping console output
exec > >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }

# Enhanced error handling
error_handler() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line $line_number with exit code $exit_code"
    log_error "Last command: $BASH_COMMAND"
    log_error "Full log available at: $LOG_FILE"
    exit $exit_code
}

trap 'error_handler $LINENO' ERR

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform-branch)
            PLATFORM_BRANCH="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--platform-branch <branch>]"
            echo ""
            echo "Options:"
            echo "  --platform-branch  Branch of zerotouch-platform to use (default: main)"
            echo "  --help, -h         Show this help message"
            echo ""
            echo "Prerequisites:"
            echo "  1. .env file with required environment variables"
            echo "  2. zerotouch-platform directory at: $PLATFORM_DIR"
            echo "  3. Docker, kubectl, and Kind installed"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Cleanup function
cleanup() {
    local exit_code=$?
    log_info "Cleaning up..."
    
    # COMMENTED OUT FOR DEBUGGING - Keep cluster running to investigate issues
    # # Cleanup preview environment if it exists
    # if [ -d "$PLATFORM_DIR" ] && [ -f "$PLATFORM_DIR/scripts/bootstrap/cleanup-preview.sh" ]; then
    #     log_info "Running platform cleanup..."
    #     cd "$PLATFORM_DIR"
    #     chmod +x scripts/bootstrap/cleanup-preview.sh
    #     ./scripts/bootstrap/cleanup-preview.sh || log_warning "Platform cleanup failed"
    # fi
    
    # Clean up fresh platform directory
    FRESH_PLATFORM_DIR="$WORKSPACE_ROOT/zerotouch-platform-fresh"
    if [ -d "$FRESH_PLATFORM_DIR" ]; then
        log_info "Removing fresh platform directory..."
        rm -rf "$FRESH_PLATFORM_DIR"
    fi
    
    cd "$REPO_ROOT"
    log_info "Log file saved at: $LOG_FILE"
    log_info "Cluster kept running for debugging - use 'kind delete cluster zerotouch-preview' to clean up manually"
    exit $exit_code
}

trap cleanup EXIT INT TERM

echo "================================================================================"
echo "NATS Events Integration Tests - Local Execution"
echo "================================================================================"
echo "  Platform Branch: $PLATFORM_BRANCH"
echo "  Workspace:       $WORKSPACE_ROOT"
echo "  Platform Dir:    $PLATFORM_DIR"
echo "  Artifacts Dir:   $ARTIFACTS_DIR"
echo "================================================================================"

# Step 1: Load environment variables
log_info "Loading environment variables from .env..."
if [ -f "$REPO_ROOT/.env" ]; then
    # Export variables from .env file
    set -a  # automatically export all variables
    source "$REPO_ROOT/.env"
    set +a  # stop automatically exporting
    log_success "Environment variables loaded from .env"
else
    log_error ".env file not found at $REPO_ROOT/.env"
    exit 1
fi

# Step 2: Validate prerequisites
log_info "Validating prerequisites..."

# Check if zerotouch-platform exists
if [ ! -d "$PLATFORM_DIR" ]; then
    log_error "zerotouch-platform repository not found at: $PLATFORM_DIR"
    exit 1
fi

# Check required tools
MISSING_TOOLS=()
for tool in docker kubectl kind; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    log_error "Missing required tools:"
    printf '  - %s\n' "${MISSING_TOOLS[@]}"
    exit 1
fi

log_success "Prerequisites validated"

# Step 3: Create artifacts directory
mkdir -p "$ARTIFACTS_DIR"

# Step 4: Create fresh platform directory (like CI does)
log_info "Creating fresh platform directory for clean Git state..."

# Create a temporary directory for the fresh platform checkout
FRESH_PLATFORM_DIR="$WORKSPACE_ROOT/zerotouch-platform-fresh"

# Remove existing fresh directory if it exists
if [ -d "$FRESH_PLATFORM_DIR" ]; then
    log_info "Removing existing fresh platform directory..."
    rm -rf "$FRESH_PLATFORM_DIR"
fi

# Clone the platform repository to get a clean Git state
log_info "Cloning platform repository for clean Git state..."
git clone "$PLATFORM_DIR" "$FRESH_PLATFORM_DIR"

# Switch to the specified branch
cd "$FRESH_PLATFORM_DIR"
if [ "$PLATFORM_BRANCH" != "main" ]; then
    log_info "Switching to branch: $PLATFORM_BRANCH"
    git checkout "$PLATFORM_BRANCH" || {
        log_warning "Branch $PLATFORM_BRANCH not found, staying on current branch"
    }
fi

# Update PLATFORM_DIR to point to the fresh directory
PLATFORM_DIR="$FRESH_PLATFORM_DIR"

log_success "Fresh platform directory created at: $PLATFORM_DIR"

# Step 5: Export AWS credentials as environment variables (if provided)
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    log_info "Exporting AWS credentials..."
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN
    log_success "AWS credentials exported"
else
    log_warning "AWS credentials not provided - some steps may fail"
fi

# Step 6: Set up Python environment
log_info "Setting up Python environment..."
cd "$REPO_ROOT"

# Check if we're in a virtual environment, if not create one
if [ -z "${VIRTUAL_ENV:-}" ]; then
    log_info "Creating Python virtual environment..."
    python3 -m venv .venv
    source .venv/bin/activate
    log_success "Virtual environment activated"
else
    log_info "Using existing virtual environment: $VIRTUAL_ENV"
fi

# Install dependencies
log_info "Installing Python dependencies..."
python -m pip install --upgrade pip
pip install -e ".[dev]"
log_success "Python dependencies installed"

# Step 7: Bootstrap Platform Preview Environment
log_info "Bootstrapping platform preview environment..."
cd "$PLATFORM_DIR"
chmod +x scripts/bootstrap/01-master-bootstrap.sh
./scripts/bootstrap/01-master-bootstrap.sh --mode preview
log_success "Platform preview environment bootstrapped"

# Step 8: Build Docker Image
log_info "Building Docker image..."
cd "$REPO_ROOT"
chmod +x scripts/ci/build.sh
./scripts/ci/build.sh --mode=test
log_success "Docker image built and loaded into Kind cluster"

# Step 9: Apply Preview Patches
log_info "Applying preview patches..."
chmod +x scripts/patches/00-apply-all-patches.sh
./scripts/patches/00-apply-all-patches.sh --force
log_success "Preview patches applied"

# Step 10: Pre-Deploy Diagnostics
log_info "Running pre-deploy diagnostics..."
chmod +x scripts/ci/pre-deploy-diagnostics.sh
./scripts/ci/pre-deploy-diagnostics.sh
log_success "Pre-deploy diagnostics completed"

# Step 11: Deploy Service
log_info "Deploying service..."
export ZEROTOUCH_PLATFORM_DIR="$PLATFORM_DIR"
chmod +x scripts/ci/deploy.sh
./scripts/ci/deploy.sh preview
log_success "Service deployed successfully"

# Step 12: Post-Deploy Diagnostics
log_info "Running post-deploy diagnostics..."
chmod +x scripts/ci/post-deploy-diagnostics.sh
./scripts/ci/post-deploy-diagnostics.sh intelligence-deepagents deepagents-runtime
log_success "Post-deploy diagnostics completed"

# Step 13: Run NATS Events Integration Tests
log_info "Running NATS Events Integration Tests..."
export ZEROTOUCH_PLATFORM_DIR="$PLATFORM_DIR"
export USE_MOCK_LLM="${USE_MOCK_LLM:-true}"
export MOCK_TIMEOUT="${MOCK_TIMEOUT:-60}"

log_info "Deploying in-cluster test job..."
kubectl delete job nats-integration-tests -n intelligence-deepagents --ignore-not-found=true
kubectl apply -f scripts/ci/test-job.yaml

log_info "Waiting for test job to complete..."
TIMEOUT=600
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
    JOB_STATUS=$(kubectl get job nats-integration-tests -n intelligence-deepagents -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
    
    if [ "$JOB_STATUS" = "Complete" ]; then
        log_success "Job completed successfully after ${ELAPSED}s"
        break
    elif [ "$JOB_STATUS" = "Failed" ]; then
        log_error "Job failed after ${ELAPSED}s"
        break
    else
        POD_STATUS=$(kubectl get pods -n intelligence-deepagents -l job-name=nats-integration-tests -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
        READY_COUNT=$(kubectl get pods -n intelligence-deepagents -l job-name=nats-integration-tests -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        
        log_info "[${ELAPSED}s/${TIMEOUT}s] Job: ${JOB_STATUS:-Pending}, Pod: ${POD_STATUS}, Ready: ${READY_COUNT}"
        
        if [ "$POD_STATUS" = "Running" ]; then
            log_info "Recent logs:"
            kubectl logs -n intelligence-deepagents -l job-name=nats-integration-tests --tail=5 2>/dev/null | sed 's/^/  /' || echo "  No logs available yet"
        fi
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log_error "Job timed out after ${TIMEOUT}s"
    kubectl describe job nats-integration-tests -n intelligence-deepagents
    kubectl describe pods -n intelligence-deepagents -l job-name=nats-integration-tests
    exit 1
fi

log_info "Getting test results..."
kubectl logs job/nats-integration-tests -n intelligence-deepagents

# Copy artifacts from the job pod
POD_NAME=$(kubectl get pods -n intelligence-deepagents -l job-name=nats-integration-tests -o jsonpath='{.items[0].metadata.name}')
if [ ! -z "$POD_NAME" ]; then
    log_info "Copying artifacts from pod: $POD_NAME"
    mkdir -p "$ARTIFACTS_DIR"
    kubectl cp intelligence-deepagents/$POD_NAME:/app/artifacts/ "$ARTIFACTS_DIR/" || log_warning "No artifacts to copy"
fi

# Check if job succeeded
JOB_STATUS=$(kubectl get job nats-integration-tests -n intelligence-deepagents -o jsonpath='{.status.conditions[0].type}')
if [ "$JOB_STATUS" != "Complete" ]; then
    log_error "Test job failed"
    exit 1
fi

log_success "NATS Events Integration Tests completed"

echo "================================================================================"
log_success "NATS Events Integration Tests completed successfully!"
log_info "Log file saved at: $LOG_FILE"
echo "================================================================================"