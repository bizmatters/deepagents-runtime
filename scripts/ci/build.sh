#!/bin/bash
set -e

# ==============================================================================
# Tier 3 CI Script: Build Production Docker Image
# ==============================================================================
# Purpose: Atomic primitive for building the agent-executor production image
# Owner: Backend Developer
# Called by: Tier 2 orchestration scripts (platform/scripts/ci/*)
#
# Environment Variables (CI-provided):
#   - PR_NUMBER: Pull request number (optional)
#   - IMAGE_TAG: Image tag override (optional)
#   - DOCKER_REGISTRY: Docker registry URL (optional)
#
# Output: Echoes fully-qualified image name for Tier 2 consumption
# ==============================================================================

# Configuration
SERVICE_NAME="agent-executor"
GIT_SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# DOCKER_REGISTRY must be provided by the Tier 2 orchestrator
# This script does not auto-detect or assume defaults
if [ -z "${DOCKER_REGISTRY}" ]; then
    echo "ERROR: DOCKER_REGISTRY environment variable is required"
    echo "This script must be called by a Tier 2 orchestrator that sets DOCKER_REGISTRY"
    exit 1
fi

# Note: Docker authentication is handled by the Tier 1/2 orchestrator (GitHub Actions)
# This script assumes docker is already authenticated to the target registry
echo "→ Using registry: ${DOCKER_REGISTRY}"

# Determine image tag
if [ -n "${PR_NUMBER}" ]; then
    IMAGE_TAG="${IMAGE_TAG:-pr-${PR_NUMBER}-${GIT_SHORT_SHA}}"
else
    IMAGE_TAG="${IMAGE_TAG:-local-${GIT_SHORT_SHA}}"
fi

FULL_IMAGE_NAME="${DOCKER_REGISTRY}/${SERVICE_NAME}:${IMAGE_TAG}"

echo "================================================================================"
echo "Building ${SERVICE_NAME} Docker Image"
echo "================================================================================"
echo "  Registry:  ${DOCKER_REGISTRY}"
echo "  Service:   ${SERVICE_NAME}"
echo "  Tag:       ${IMAGE_TAG}"
echo "  Full Name: ${FULL_IMAGE_NAME}"
echo "================================================================================"

# Build the image from monorepo root
# Context is monorepo root because Dockerfile copies from services/agent_executor/
# CI mode: Always use --no-cache and --pull for reproducible builds
docker build \
    -f ./services/agent_executor/Dockerfile \
    -t "${FULL_IMAGE_NAME}" \
    --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --build-arg GIT_COMMIT="${GIT_SHORT_SHA}" \
    --no-cache \
    --pull \
    .

echo ""
echo "✅ Build complete: ${FULL_IMAGE_NAME}"
echo ""

# Push to registry (CI workflow standard)
echo "→ Pushing image to registry: ${DOCKER_REGISTRY}"
docker push "${FULL_IMAGE_NAME}"
echo "✅ Push complete: ${FULL_IMAGE_NAME}"

# Also push as latest if PUSH_LATEST is set
if [ "${PUSH_LATEST}" = "true" ]; then
    LATEST_IMAGE="${DOCKER_REGISTRY}/${SERVICE_NAME}:latest"
    echo ""
    echo "→ Tagging and pushing as latest..."
    docker tag "${FULL_IMAGE_NAME}" "${LATEST_IMAGE}"
    docker push "${LATEST_IMAGE}"
    echo "✅ Push complete: ${LATEST_IMAGE}"
fi

echo ""

# Echo image name for Tier 2 script consumption
echo "${FULL_IMAGE_NAME}"
