#!/bin/bash
#
# Tier 2 Orchestration Script: Integration Test Workflow
#
# This script orchestrates the execution of Tier 3 scripts to run integration tests
# for deepagnets-runtime against zerotouch-platform APIs in a preview environment.
#
# Environment Variables (required):
#   ZEROTOUCH_PLATFORM_DIR - Path to cloned zerotouch-platform repository
#   AWS_ACCESS_KEY_ID      - AWS access key for ESO
#   AWS_SECRET_ACCESS_KEY  - AWS secret key for ESO
#   AWS_SESSION_TOKEN      - AWS session token for ESO (optional)
#
# Environment Variables (optional):
#   PLATFORM_BRANCH        - zerotouch-platform branch (default: main)
#   SKIP_CLEANUP          - Skip cleanup on success (default: false)
#
# Exit Codes:
#   0 - Success
#   1 - Setup failure
#   2 - Platform installation failure
#   3 - Deployment failure
#   4 - Test failure
#   5 - Environment validation failure

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TIER3_SCRIPTS_DIR="${PROJECT_ROOT}/tests/integration/scripts"

# Artifacts directory
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"
mkdir -p "${ARTIFACTS_DIR}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Cleanup function - always runs
cleanup() {
    local exit_code=$?
    
    log_section "Running Cleanup"
    
    if [ -f "${TIER3_SCRIPTS_DIR}/cleanup.sh" ]; then
        log_info "Executing cleanup script..."
        bash "${TIER3_SCRIPTS_DIR}/cleanup.sh" || {
            log_warning "Cleanup script failed, but continuing..."
        }
    else
        log_warning "Cleanup script not found at ${TIER3_SCRIPTS_DIR}/cleanup.sh"
    fi
    
    if [ $exit_code -eq 0 ]; then
        log_success "Integration tests completed successfully"
    else
        log_error "Integration tests failed with exit code: $exit_code"
    fi
    
    exit $exit_code
}

# Register cleanup to run on exit
trap cleanup EXIT

# Validate environment variables
validate_environment() {
    log_section "Validating Environment"
    
    local missing_vars=()
    
    # Check required environment variables
    if [ -z "${ZEROTOUCH_PLATFORM_DIR:-}" ]; then
        missing_vars+=("ZEROTOUCH_PLATFORM_DIR")
    fi
    
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        missing_vars+=("AWS_ACCESS_KEY_ID")
    fi
    
    if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        missing_vars+=("AWS_SECRET_ACCESS_KEY")
    fi
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            log_error "  - $var"
        done
        return 5
    fi
    
    # Validate zerotouch-platform directory exists
    if [ ! -d "${ZEROTOUCH_PLATFORM_DIR}" ]; then
        log_error "zerotouch-platform directory not found: ${ZEROTOUCH_PLATFORM_DIR}"
        return 5
    fi
    
    # Validate Tier 3 scripts directory exists
    if [ ! -d "${TIER3_SCRIPTS_DIR}" ]; then
        log_error "Tier 3 scripts directory not found: ${TIER3_SCRIPTS_DIR}"
        log_error "Expected location: ${TIER3_SCRIPTS_DIR}"
        return 5
    fi
    
    # Log environment information
    log_info "Project root: ${PROJECT_ROOT}"
    log_info "Tier 3 scripts: ${TIER3_SCRIPTS_DIR}"
    log_info "Platform directory: ${ZEROTOUCH_PLATFORM_DIR}"
    log_info "Platform branch: ${PLATFORM_BRANCH:-feature/agent-executor}"
    log_info "Artifacts directory: ${ARTIFACTS_DIR}"
    log_info "AWS credentials: configured"
    
    log_success "Environment validation passed"
    return 0
}

# Execute Tier 3 script with error handling
execute_tier3_script() {
    local script_name=$1
    local script_path="${TIER3_SCRIPTS_DIR}/${script_name}"
    local exit_code_on_failure=$2
    
    if [ ! -f "${script_path}" ]; then
        log_error "Script not found: ${script_path}"
        return "${exit_code_on_failure}"
    fi
    
    if [ ! -x "${script_path}" ]; then
        log_info "Making script executable: ${script_name}"
        chmod +x "${script_path}"
    fi
    
    log_info "Executing: ${script_name}"
    
    if bash "${script_path}"; then
        log_success "${script_name} completed successfully"
        return 0
    else
        local actual_exit_code=$?
        log_error "${script_name} failed with exit code: ${actual_exit_code}"
        return "${exit_code_on_failure}"
    fi
}

# Main execution flow
main() {
    log_section "DeepAgents Integration Tests - Tier 2 Orchestrator"
    log_info "Starting integration test workflow..."
    
    # Step 1: Validate environment
    validate_environment || exit $?
    
    # Step 2: Setup preview cluster
    log_section "Step 1: Setting Up Preview Cluster"
    execute_tier3_script "setup-preview-cluster.sh" 1 || exit $?
    
    # Step 3: Install platform APIs
    log_section "Step 2: Installing Platform APIs"
    execute_tier3_script "install-platform-apis.sh" 2 || exit $?
    
    # Step 4: Deploy service
    log_section "Step 3: Deploying DeepAgents Runtime"
    execute_tier3_script "deploy-service.sh" 3 || exit $?
    
    # Step 5: Run tests
    log_section "Step 4: Running Integration Tests"
    execute_tier3_script "run-tests.sh" 4 || exit $?
    
    log_success "All steps completed successfully!"
    return 0
}

# Execute main function
main
