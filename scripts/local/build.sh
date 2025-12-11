#!/bin/bash
set -euo pipefail

# ==============================================================================
# Tier 2 Local Script: Build Development Docker Image
# ==============================================================================
# Purpose: Build Docker image for local development with caching
# Called by: Developer via terminal
# ==============================================================================

# Configuration
SERVICE_NAME="deepagents-runtime"
GIT_SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
IMAGE_TAG="local-${GIT_SHORT_SHA}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "================================================================================"
echo "Building Docker Image (Local Development)"
echo "================================================================================"
echo "  Service:   ${SERVICE_NAME}"
echo "  Tag:       ${IMAGE_TAG}"
echo "  Mode:      Local (with caching)"
echo "================================================================================"

# Build with caching enabled for faster iteration
cd "${REPO_ROOT}"
docker build \
    -f Dockerfile \
    -t "${SERVICE_NAME}:${IMAGE_TAG}" \
    -t "${SERVICE_NAME}:latest" \
    --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --build-arg GIT_COMMIT="${GIT_SHORT_SHA}" \
    .

echo ""
echo "✅ Build complete"
echo "  - ${SERVICE_NAME}:${IMAGE_TAG}"
echo "  - ${SERVICE_NAME}:latest"
echo ""

# Check if Docker Desktop Kubernetes is available
if kubectl config current-context 2>/dev/null | grep -q "docker-desktop"; then
    echo "✅ Docker Desktop Kubernetes detected"
    echo "   Image is automatically available to Kubernetes"
fi

echo "================================================================================"