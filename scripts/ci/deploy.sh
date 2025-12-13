#!/bin/bash
set -euo pipefail

# ==============================================================================
# Tier 2 CI Script: Deploy Service to Kubernetes
# ==============================================================================
# Purpose: Deploy deepagents-runtime to Kind cluster using platform claims
# Called by: GitHub Actions workflow
# Usage: ./deploy.sh [MODE]
#   MODE: "production" or "preview" (optional, defaults to auto-detection)
# ==============================================================================

# Parse mode parameter
MODE="${1:-auto}"

# Configuration
NAMESPACE="intelligence-deepagents"
IMAGE_NAME="deepagents-runtime"
IMAGE_TAG="ci-test"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAIMS_DIR="${REPO_ROOT}/platform/claims/intelligence-deepagents"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "================================================================================"
echo "Deploying DeepAgents Runtime to Kubernetes"
echo "================================================================================"
echo "  Namespace: ${NAMESPACE}"
echo "  Image:     ${IMAGE_NAME}:${IMAGE_TAG}"
echo "================================================================================"

# Step 1: Create namespace
log_info "Creating namespace..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Apply ExternalSecret for LLM keys
log_info "Applying ExternalSecret for LLM keys..."
kubectl apply -f "${CLAIMS_DIR}/external-secrets/llm-keys-es.yaml"

# Wait for secret to be created
log_info "Waiting for LLM keys secret..."
kubectl wait secret/deepagents-runtime-llm-keys \
    -n "${NAMESPACE}" \
    --for=jsonpath='{.data}' \
    --timeout=120s

# Step 3: Apply database claims
log_info "Applying database claims..."
kubectl apply -f "${CLAIMS_DIR}/postgres-claim.yaml"
kubectl apply -f "${CLAIMS_DIR}/dragonfly-claim.yaml"

# Wait for database secrets
log_info "Waiting for database connection secrets..."
kubectl wait secret/deepagents-runtime-db-conn \
    -n "${NAMESPACE}" \
    --for=jsonpath='{.data}' \
    --timeout=300s

kubectl wait secret/deepagents-runtime-cache-conn \
    -n "${NAMESPACE}" \
    --for=jsonpath='{.data}' \
    --timeout=300s

# Step 4: Apply EventDrivenService claim with correct image
log_info "Applying EventDrivenService claim..."
TEMP_CLAIM=$(mktemp)

# Determine deployment mode and resource sizing
if [ "$MODE" = "preview" ]; then
    log_info "Preview mode - using micro size for resource optimization..."
    sed "s|image: ghcr.io/arun4infra/deepagents-runtime:latest|image: ${IMAGE_NAME}:${IMAGE_TAG}|g" \
        "${CLAIMS_DIR}/deepagents-runtime-deployment.yaml" | \
    sed 's|size: small|size: micro|g' | \
    sed '/imagePullSecrets:/,+1d' > "${TEMP_CLAIM}"
elif [ "$MODE" = "production" ]; then
    log_info "Production mode - using standard small size..."
    sed "s|image: ghcr.io/arun4infra/deepagents-runtime:latest|image: ${IMAGE_NAME}:${IMAGE_TAG}|g" \
        "${CLAIMS_DIR}/deepagents-runtime-deployment.yaml" | \
    sed '/imagePullSecrets:/,+1d' > "${TEMP_CLAIM}"
else
    # Auto-detection fallback
    log_info "Auto-detecting cluster type..."
    if ! kubectl get nodes -o jsonpath='{.items[*].spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")]}' | grep -q "control-plane"; then
        log_info "Detected Kind cluster - using micro size for resource optimization..."
        sed "s|image: ghcr.io/arun4infra/deepagents-runtime:latest|image: ${IMAGE_NAME}:${IMAGE_TAG}|g" \
            "${CLAIMS_DIR}/deepagents-runtime-deployment.yaml" | \
        sed 's|size: small|size: micro|g' | \
        sed '/imagePullSecrets:/,+1d' > "${TEMP_CLAIM}"
    else
        log_info "Detected Talos cluster - using standard small size..."
        sed "s|image: ghcr.io/arun4infra/deepagents-runtime:latest|image: ${IMAGE_NAME}:${IMAGE_TAG}|g" \
            "${CLAIMS_DIR}/deepagents-runtime-deployment.yaml" | \
        sed '/imagePullSecrets:/,+1d' > "${TEMP_CLAIM}"
    fi
fi

kubectl apply -f "${TEMP_CLAIM}"

# Debug: Verify the claim was applied correctly
echo "=== Verifying EventDrivenService claim ==="
echo "Applied claim content:"
cat "${TEMP_CLAIM}"
echo ""
echo "Checking if EventDrivenService was created..."
kubectl get eventdrivenservice deepagents-runtime -n "${NAMESPACE}" -o yaml || echo "EventDrivenService not found immediately after apply"

rm -f "${TEMP_CLAIM}"

# Step 5: Wait for deployment to be ready
log_info "Waiting for deployment to be ready..."

# Debug: Check current state before waiting
echo "=== Debugging deployment status ==="
echo "Checking EventDrivenService status..."
kubectl get eventdrivenservice -n "${NAMESPACE}" -o wide || echo "No EventDrivenService found"

echo "Checking XEventDrivenService status..."
kubectl get xeventdrivenservice -o wide || echo "No XEventDrivenService found"

echo "Checking deployments..."
kubectl get deployment -n "${NAMESPACE}" -o wide || echo "No deployments found"

echo "Checking pods..."
kubectl get pods -n "${NAMESPACE}" -o wide || echo "No pods found"

echo "Checking ReplicaSets..."
kubectl get replicaset -n "${NAMESPACE}" -o wide || echo "No ReplicaSets found"

echo "Checking recent events..."
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -15

echo "Checking Crossplane managed resources..."
kubectl get managed -o wide | grep -E "(deepagents|intelligence)" || echo "No matching managed resources"

# Wait a bit for resources to be created
echo "Waiting 30 seconds for resources to be created..."
sleep 30

echo "=== Status after 30 seconds ==="
kubectl get eventdrivenservice -n "${NAMESPACE}" -o wide || echo "No EventDrivenService found"
kubectl get deployment -n "${NAMESPACE}" -o wide || echo "No deployments found"
kubectl get pods -n "${NAMESPACE}" -o wide || echo "No pods found"

# Check if deployment exists before waiting
if kubectl get deployment/deepagents-runtime -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Deployment found, waiting for it to be ready..."
    kubectl wait deployment/deepagents-runtime \
        -n "${NAMESPACE}" \
        --for=condition=Available \
        --timeout=300s
else
    echo "ERROR: Deployment 'deepagents-runtime' not found after 30 seconds!"
    echo "Checking EventDrivenService details..."
    kubectl describe eventdrivenservice deepagents-runtime -n "${NAMESPACE}" || echo "EventDrivenService not found"
    
    echo "Checking XEventDrivenService details..."
    kubectl get xeventdrivenservice -o yaml | grep -A 50 -B 10 deepagents || echo "No XEventDrivenService with deepagents found"
    
    echo "Checking Crossplane provider status..."
    kubectl get providers || echo "No providers found"
    
    exit 1
fi

# Wait for pod to be ready
kubectl wait pod \
    -l app.kubernetes.io/name=deepagents-runtime \
    -n "${NAMESPACE}" \
    --for=condition=Ready \
    --timeout=300s

# Wait for pod to be ready
kubectl wait pod \
    -l app.kubernetes.io/name=deepagents-runtime \
    -n "${NAMESPACE}" \
    --for=condition=Ready \
    --timeout=300s

log_success "Service deployed successfully"
log_info "Namespace: ${NAMESPACE} | Image: ${IMAGE_NAME}:${IMAGE_TAG}"