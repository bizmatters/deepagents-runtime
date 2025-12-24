#!/bin/bash
set -euo pipefail

# ==============================================================================
# Local CI Testing Script for deepagents-runtime
# ==============================================================================
# Purpose: Local testing of CI workflow using platform's centralized script
# Usage: ./scripts/ci/in-cluster-test.sh
# 
# This script simply calls the platform's centralized script with no logic.
# ==============================================================================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[LOCAL-CI]${NC} $*"; }
log_success() { echo -e "${GREEN}[LOCAL-CI]${NC} $*"; }
log_error() { echo -e "${RED}[LOCAL-CI]${NC} $*"; }

main() {
    echo "================================================================================"
    echo "Local CI Testing for deepagents-runtime"
    echo "================================================================================"
    
    # Clone platform if needed
    PLATFORM_BRANCH="refactor/services-shared-scripts"
    BRANCH_FOLDER_NAME=$(echo "$PLATFORM_BRANCH" | sed 's/\//-/g')
    PLATFORM_CHECKOUT_DIR="zerotouch-platform-${BRANCH_FOLDER_NAME}"
    
    if [[ ! -d "$PLATFORM_CHECKOUT_DIR" ]]; then
        log_info "Cloning zerotouch-platform repository (branch: $PLATFORM_BRANCH)..."
        git clone -b "$PLATFORM_BRANCH" https://github.com/arun4infra/zerotouch-platform.git "$PLATFORM_CHECKOUT_DIR"
    fi
    
    # Run centralized platform script
    PLATFORM_SCRIPT="${PLATFORM_CHECKOUT_DIR}/scripts/bootstrap/preview/tenants/scripts/in-cluster-test.sh"
    chmod +x "$PLATFORM_SCRIPT"
    
    log_info "Executing centralized platform script..."
    "$PLATFORM_SCRIPT"
}

main "$@"