#!/bin/bash
set -euo pipefail

# ==============================================================================
# Local CI Testing Script for deepagents-runtime
# ==============================================================================
# Purpose: Local testing using platform's centralized script
# Usage: ./scripts/ci/in-cluster-test.sh
# ==============================================================================

# Clone platform if needed (using the correct branch)
if [[ ! -d "zerotouch-platform" ]]; then
    git clone -b refactor/services-shared-scripts https://github.com/arun4infra/zerotouch-platform.git
fi

# Run centralized script (no arguments needed)
./zerotouch-platform/scripts/bootstrap/preview/tenants/scripts/in-cluster-test.sh