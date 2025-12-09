#!/bin/bash
set -e

# ==============================================================================
# Tier 3 Local Script: Build Development Docker Image
# ==============================================================================
# Purpose: Build agent-executor image for local development with caching
# Owner: Backend Developer
# Called by: Developer via terminal
#
# Features:
#   - Uses Docker layer caching for speed
#   - Tags as 'local' for easy identification
#   - Does NOT push to any registry
#   - Image available immediately to Docker Desktop Kubernetes
#
# Usage:
#   ./services/agent_executor/scripts/local/build.sh
#
# Environment:
#   - No environment variables required
#   - NEVER called by CI
# ==============================================================================

# Configuration
SERVICE_NAME="agent-executor"
GIT_SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
IMAGE_TAG="local-${GIT_SHORT_SHA}"
IMAGE_NAME="${SERVICE_NAME}:${IMAGE_TAG}"

echo "================================================================================"
echo "Building ${SERVICE_NAME} Docker Image (Local Development)"
echo "================================================================================"
echo "  Service:   ${SERVICE_NAME}"
echo "  Tag:       ${IMAGE_TAG}"
echo "  Image:     ${IMAGE_NAME}"
echo "  Mode:      Local (with caching, no push)"
echo "================================================================================"

# Build with caching enabled for faster iteration
docker build \
    -f ./services/agent_executor/Dockerfile \
    -t "${IMAGE_NAME}" \
    -t "${SERVICE_NAME}:latest" \
    --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --build-arg GIT_COMMIT="${GIT_SHORT_SHA}" \
    .

echo ""
echo "✅ Build complete: ${IMAGE_NAME}"
echo ""
echo "Image is available locally:"
echo "  - ${IMAGE_NAME}"
echo "  - ${SERVICE_NAME}:latest"
echo ""

# Check if Docker Desktop Kubernetes is available
if kubectl config current-context 2>/dev/null | grep -q "docker-desktop"; then
    echo "✅ Docker Desktop Kubernetes detected"
    echo "   Image is automatically available to Kubernetes"
    echo ""
    echo "To deploy locally:"
    echo "  kubectl apply -f infrastructure/k8s/langgraph/agent-executor-service.yaml"
    echo "  (Update image to: ${IMAGE_NAME})"
fi

echo ""
echo "================================================================================"
