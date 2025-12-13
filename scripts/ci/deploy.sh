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

# Step 0: Validate platform dependencies
log_info "Validating platform dependencies..."
"${REPO_ROOT}/scripts/ci/validate-platform-dependencies.sh"

# Pre-flight checks
log_info "Running pre-flight checks..."
echo "Checking Crossplane providers..."
kubectl get providers -o wide || echo "No Crossplane providers found"

echo "Checking XRDs..."
kubectl get xrd | grep -E "(eventdriven|postgres|dragonfly)" || echo "Required XRDs not found"

echo "Checking Compositions..."
kubectl get compositions | grep -E "(event-driven|postgres|dragonfly)" || echo "Required Compositions not found"

echo "Checking if platform is ready..."
if ! kubectl get xrd xeventdrivenservices.platform.bizmatters.io >/dev/null 2>&1; then
    log_error "EventDrivenService XRD not found! Platform may not be ready."
    exit 1
fi

echo "Checking cluster resource usage..."
echo "=== Node Resources ==="
kubectl top nodes || echo "Metrics server not available for node stats"

echo "=== Pod Resources (All Namespaces) ==="
kubectl top pods --all-namespaces --sort-by=memory || echo "Metrics server not available for pod stats"

echo "=== Node Capacity and Allocatable ==="
kubectl describe nodes | grep -E "(Name:|Capacity:|Allocatable:|Allocated resources:)" || echo "Could not get node capacity info"

echo "=== Resource Quotas ==="
kubectl get resourcequota --all-namespaces || echo "No resource quotas found"

log_info "Pre-flight checks completed"

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

echo "=== Resource Usage During Deployment ==="
echo "Node resource usage:"
kubectl top nodes || echo "Metrics server not available"

echo "Pod resource usage in target namespace:"
kubectl top pods -n "${NAMESPACE}" || echo "No pods running yet or metrics unavailable"

echo "All pod resource usage (top 10 by memory):"
kubectl top pods --all-namespaces --sort-by=memory | head -11 || echo "Metrics server not available"

# Check if deployment exists before waiting
if kubectl get deployment/deepagents-runtime -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Deployment found, checking pod status..."
    
    # Check if pods are failing
    POD_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    echo "Pod status: $POD_STATUS"
    
    if [ "$POD_STATUS" = "Failed" ] || kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime | grep -E "(Error|CrashLoopBackOff|ImagePullBackOff)"; then
        echo "=== Pod is failing, checking logs ==="
        POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$POD_NAME" ]; then
            echo "Getting logs from pod: $POD_NAME"
            kubectl logs "$POD_NAME" -n "${NAMESPACE}" --previous || echo "No previous logs available"
            kubectl logs "$POD_NAME" -n "${NAMESPACE}" || echo "No current logs available"
            
            echo "Describing pod for more details:"
            kubectl describe pod "$POD_NAME" -n "${NAMESPACE}"
        fi
        
        echo "=== Checking cache pod status ==="
        CACHE_POD=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime-cache -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$CACHE_POD" ]; then
            echo "Cache pod status:"
            kubectl describe pod "$CACHE_POD" -n "${NAMESPACE}"
        fi
        
        echo "=== Checking resource constraints ==="
        kubectl describe nodes | grep -A 10 -B 5 "Resource\|Pressure\|Condition" || echo "Could not get node resource info"
    fi
    
    echo "Waiting for deployment to be ready..."
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
    
    echo "=== Final Resource Analysis ==="
    echo "Current node resource usage:"
    kubectl top nodes || echo "Metrics server not available"
    
    echo "Memory and CPU pressure on nodes:"
    kubectl describe nodes | grep -A 5 -B 5 -E "(MemoryPressure|DiskPressure|PIDPressure|Ready)" || echo "Could not get node conditions"
    
    echo "Pod resource requests vs limits in cluster:"
    kubectl describe nodes | grep -A 20 "Allocated resources:" || echo "Could not get allocated resources"
    
    echo "Failed/Pending pods that might indicate resource issues:"
    kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded || echo "No failed/pending pods"
    
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