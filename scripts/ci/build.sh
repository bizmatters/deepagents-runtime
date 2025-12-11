#!/bin/bash
set -euo pipefail

# ==============================================================================
# Tier 2 CI Script: Build Docker Image
# ==============================================================================
# Purpose: Build Docker image for testing (Kind) or production (Registry push)
# Usage: ./scripts/ci/build.sh [--mode=test|production]
# Called by: GitHub Actions workflows
# ==============================================================================

# Configuration
SERVICE_NAME="deepagents-runtime"
REGISTRY="ghcr.io/arun4infra"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
MODE="test"  # Default mode
for arg in "$@"; do
    case $arg in
        --mode=*)
            MODE="${arg#*=}"
            shift
            ;;
        *)
            # Unknown option
            ;;
    esac
done

# Validate mode
if [[ "$MODE" != "test" && "$MODE" != "production" ]]; then
    log_error "Invalid mode: $MODE. Use 'test' or 'production'"
    exit 1
fi

echo "================================================================================"
echo "Building Docker Image"
echo "================================================================================"
echo "  Service:   ${SERVICE_NAME}"
echo "  Mode:      ${MODE}"
echo "  Registry:  ${REGISTRY}"
echo "================================================================================"

cd "${REPO_ROOT}"

if [[ "$MODE" == "test" ]]; then
    # ========================================================================
    # TEST MODE: Build and load into Kind cluster
    # ========================================================================
    IMAGE_TAG="ci-test"
    CLUSTER_NAME="zerotouch-preview"
    
    log_info "Building Docker image for testing..."
    docker build \
        -f Dockerfile \
        -t "${SERVICE_NAME}:${IMAGE_TAG}" \
        --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --build-arg GIT_COMMIT="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')}" \
        .
    
    log_success "Docker image built successfully"
    
    log_info "Loading image into Kind cluster..."
    if ! kind load docker-image "${SERVICE_NAME}:${IMAGE_TAG}" --name "${CLUSTER_NAME}"; then
        log_error "Failed to load image into Kind cluster"
        exit 1
    fi
    
    log_success "Image loaded successfully into Kind cluster"
    log_success "Build and load complete: ${SERVICE_NAME}:${IMAGE_TAG}"

elif [[ "$MODE" == "production" ]]; then
    # ========================================================================
    # PRODUCTION MODE: Build and push to registry
    # ========================================================================
    
    # Validate required environment variables
    REQUIRED_VARS=("GITHUB_SHA" "GITHUB_REF_NAME")
    MISSING_VARS=()
    
    for var in "${REQUIRED_VARS[@]}"; do
        if [ -z "${!var:-}" ]; then
            MISSING_VARS+=("$var")
        fi
    done
    
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        log_error "Missing required environment variables for production mode:"
        printf '  - %s\n' "${MISSING_VARS[@]}"
        exit 1
    fi
    
    # Determine image tags based on git ref
    TAGS=()
    SHORT_SHA=$(echo "${GITHUB_SHA}" | cut -c1-7)
    
    if [[ "${GITHUB_REF_NAME}" == "main" ]]; then
        # Main branch: tag with branch-sha and latest
        TAGS+=("${REGISTRY}/${SERVICE_NAME}:main-${SHORT_SHA}")
        TAGS+=("${REGISTRY}/${SERVICE_NAME}:latest")
    elif [[ "${GITHUB_REF_NAME}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*$ ]]; then
        # Version tag: use semantic versioning
        VERSION="${GITHUB_REF_NAME#v}"  # Remove 'v' prefix
        TAGS+=("${REGISTRY}/${SERVICE_NAME}:${VERSION}")
        TAGS+=("${REGISTRY}/${SERVICE_NAME}:${VERSION%.*}")  # Major.minor
        TAGS+=("${REGISTRY}/${SERVICE_NAME}:${VERSION%%.*}") # Major only
    else
        # Feature branch or PR: tag with branch-sha
        SAFE_BRANCH=$(echo "${GITHUB_REF_NAME}" | sed 's/[^a-zA-Z0-9._-]/-/g')
        TAGS+=("${REGISTRY}/${SERVICE_NAME}:${SAFE_BRANCH}-${SHORT_SHA}")
    fi
    
    # Build Docker image with all tags
    log_info "Building Docker image for production..."
    TAG_ARGS=()
    for tag in "${TAGS[@]}"; do
        TAG_ARGS+=("-t" "$tag")
    done
    
    docker build \
        -f Dockerfile \
        "${TAG_ARGS[@]}" \
        --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --build-arg GIT_COMMIT="${GITHUB_SHA}" \
        .
    
    log_success "Docker image built successfully"
    
    # Push all tags to registry
    log_info "Pushing images to registry..."
    for tag in "${TAGS[@]}"; do
        log_info "Pushing: ${tag}"
        docker push "$tag"
    done
    
    log_success "All images pushed successfully"
    
    # Update deployment manifest if on main branch
    if [[ "${GITHUB_REF_NAME}" == "main" ]]; then
        log_info "Updating deployment manifest for main branch..."
        
        DEPLOYMENT_FILE="platform/claims/intelligence-deepagents/deepagents-runtime-deployment.yaml"
        NEW_IMAGE="${REGISTRY}/${SERVICE_NAME}:main-${SHORT_SHA}"
        
        if [ -f "$DEPLOYMENT_FILE" ]; then
            # Update image tag in deployment file
            sed -i "s|image: ${REGISTRY}/${SERVICE_NAME}:.*|image: ${NEW_IMAGE}|g" "$DEPLOYMENT_FILE"
            
            log_success "Updated deployment manifest with image: ${NEW_IMAGE}"
            
            # Output for GitHub Actions to commit the change
            echo "DEPLOYMENT_UPDATED=true" >> "${GITHUB_OUTPUT:-/dev/null}"
            echo "NEW_IMAGE=${NEW_IMAGE}" >> "${GITHUB_OUTPUT:-/dev/null}"
        else
            log_error "Deployment file not found: $DEPLOYMENT_FILE"
            exit 1
        fi
    fi
    
    # Output primary image tag for downstream use
    PRIMARY_TAG="${TAGS[0]}"
    echo "PRIMARY_IMAGE=${PRIMARY_TAG}" >> "${GITHUB_OUTPUT:-/dev/null}"
    
    log_success "Build and push completed successfully"
    echo "Primary image: ${PRIMARY_TAG}"
fi