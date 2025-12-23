#!/bin/bash
set -euo pipefail

# ==============================================================================
# Tier 2 CI Script: Deploy Service to Kubernetes
# ==============================================================================
# Purpose: Deploy deepagents-runtime to Kind cluster using platform claims
# Called by: GitHub Actions workflow
# Usage: ./deploy.sh [MODE]
#   MODE: "production" or "preview" (optional, defaults to auto-detection)
#
# IMPORTANT: Preview vs Production Namespace Handling
# - Production: Namespaces created by tenant-infrastructure (ArgoCD app)
# - Preview: Namespaces created by this CI script (mocks landing zones)
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

if ! kubectl get xrd xeventdrivenservices.platform.bizmatters.io >/dev/null 2>&1; then
    log_error "EventDrivenService XRD not found! Platform may not be ready."
    exit 1
fi

log_info "✓ Platform is ready for deployment"

# Step 1: Mock Landing Zone (Preview Mode Only)
# In Production, tenant-infrastructure creates namespaces
# In Preview, CI must simulate this behavior
log_info "Setting up landing zone for preview mode..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
log_info "✓ Mock landing zone '${NAMESPACE}' created"

# Step 2: Apply ExternalSecret for LLM keys
log_info "Applying ExternalSecret for LLM keys..."
kubectl apply -f "${CLAIMS_DIR}/external-secrets/llm-keys-es.yaml"

log_info "Waiting for LLM keys secret..."
"${REPO_ROOT}/scripts/helpers/wait-for-externalsecret.sh" deepagents-runtime-llm-keys "${NAMESPACE}" 120

# Step 3: Apply database claims
log_info "Applying database claims..."
kubectl apply -f "${CLAIMS_DIR}/postgres-claim.yaml"
kubectl apply -f "${CLAIMS_DIR}/dragonfly-claim.yaml"

# Wait for database instances to be ready
log_info "Waiting for PostgreSQL cluster..."
"${REPO_ROOT}/scripts/helpers/wait-for-postgres.sh" deepagents-runtime-db "${NAMESPACE}" 300

log_info "Waiting for Dragonfly cache..."
"${REPO_ROOT}/scripts/helpers/wait-for-dragonfly.sh" deepagents-runtime-cache "${NAMESPACE}" 300

# Wait for database connection secrets
log_info "Waiting for database connection secrets..."
"${REPO_ROOT}/scripts/helpers/wait-for-secret.sh" deepagents-runtime-db-conn "${NAMESPACE}" 60
"${REPO_ROOT}/scripts/helpers/wait-for-secret.sh" deepagents-runtime-cache-conn "${NAMESPACE}" 60

# Step 3.5: Create NATS stream and consumer
log_info "Creating NATS stream and consumer..."
kubectl apply -f "${CLAIMS_DIR}/nats-stream.yaml"

log_info "Waiting for NATS stream creation job to complete..."
if ! kubectl wait job/create-agent-execution-stream \
    -n "${NAMESPACE}" \
    --for=condition=complete \
    --timeout=60s; then
    log_error "NATS stream creation failed!"
    echo "Job logs:"
    kubectl logs -n "${NAMESPACE}" job/create-agent-execution-stream || echo "Could not retrieve logs"
    echo ""
    echo "Job status:"
    kubectl describe job/create-agent-execution-stream -n "${NAMESPACE}" || echo "Could not describe job"
    exit 1
fi

log_success "NATS stream and consumer created successfully"

# Step 3.6: Verify image is available in Kind cluster (for test mode)
if [ "$MODE" = "preview" ] || [ "$MODE" = "auto" ]; then
    log_info "Verifying image ${IMAGE_NAME}:${IMAGE_TAG} is available in Kind cluster..."
    
    # Use the same cluster name as build.sh
    KIND_CLUSTER_NAME="zerotouch-preview"
    KIND_NODE="${KIND_CLUSTER_NAME}-control-plane"
    
    # Verify the cluster exists
    if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        log_error "Kind cluster '${KIND_CLUSTER_NAME}' not found!"
        echo "Available Kind clusters:"
        kind get clusters 2>/dev/null || echo "No Kind clusters found"
        exit 1
    fi
    
    log_info "Using Kind cluster: ${KIND_CLUSTER_NAME}"
    
    # Check if the node container exists
    if ! docker ps --format '{{.Names}}' | grep -q "^${KIND_NODE}$"; then
        log_error "Kind node container '${KIND_NODE}' not found!"
        echo "Available Docker containers:"
        docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
        exit 1
    fi
    
    # Check if image exists in Kind cluster
    # Note: crictl output has multiple spaces between columns, so we need to be flexible with the pattern
    if docker exec "${KIND_NODE}" crictl images 2>/dev/null | grep -E "${IMAGE_NAME}[[:space:]]+${IMAGE_TAG}"; then
        log_success "Image found in Kind cluster"
        echo "Image details:"
        docker exec "${KIND_NODE}" crictl images | grep "${IMAGE_NAME}" || true
    else
        log_error "Image ${IMAGE_NAME}:${IMAGE_TAG} NOT found in Kind cluster!"
        echo ""
        echo "Available images in Kind (showing deepagents and recent images):"
        docker exec "${KIND_NODE}" crictl images 2>/dev/null | grep -E "deepagents|REPOSITORY" | head -20 || echo "Could not list images"
        echo ""
        echo "All images in Kind:"
        docker exec "${KIND_NODE}" crictl images 2>/dev/null | head -30 || echo "Could not list images"
        echo ""
        log_error "The image was not loaded into Kind cluster!"
        log_error "This usually means the build step failed or didn't run."
        log_error "Expected: './scripts/ci/build.sh --mode=test' should have loaded the image."
        echo ""
        echo "To fix this, ensure the build step:"
        echo "  1. Builds the Docker image: docker build -t ${IMAGE_NAME}:${IMAGE_TAG}"
        echo "  2. Loads it into Kind: kind load docker-image ${IMAGE_NAME}:${IMAGE_TAG} --name ${KIND_CLUSTER_NAME}"
        exit 1
    fi
fi

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

echo ""
echo "=== EventDrivenService Claim to be Applied ==="
cat "${TEMP_CLAIM}"
echo "=== End of Claim ==="
echo ""

log_info "Applying EventDrivenService claim to namespace: ${NAMESPACE}"
kubectl apply -f "${TEMP_CLAIM}"

# Debug: Verify the claim was applied correctly
echo ""
echo "=== Verifying EventDrivenService claim was created ==="
kubectl get eventdrivenservice deepagents-runtime -n "${NAMESPACE}" -o yaml || log_error "EventDrivenService not found immediately after apply"
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
    
    # Check pod status
    POD_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    echo "Pod status: $POD_STATUS"
    
    # Get pod name for diagnostics
    POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$POD_NAME" ]; then
        echo ""
        echo "=== Pod Details: $POD_NAME ==="
        kubectl get pod "$POD_NAME" -n "${NAMESPACE}" -o wide
        echo ""
        
        echo "=== Container Readiness Status ==="
        kubectl get pod "$POD_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[*].ready}' && echo ""
        kubectl get pod "$POD_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq '.' || echo "Ready condition unavailable"
        echo ""
        
        echo "=== Pod Logs (Last 50 lines) ==="
        kubectl logs "$POD_NAME" -n "${NAMESPACE}" --tail=50 || echo "No current logs available"
        echo ""
        
        echo "=== Pod Events ==="
        kubectl describe pod "$POD_NAME" -n "${NAMESPACE}" | grep -A 20 "Events:" || echo "No events found"
        echo ""
        
        # Check if readiness probe is failing
        echo "=== Readiness Probe Status ==="
        kubectl get pod "$POD_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[*].state}' | jq '.' || echo "Container state unavailable"
        echo ""
        
        # Try to curl the readiness endpoint from within the cluster
        echo "=== Testing Readiness Endpoint ==="
        POD_IP=$(kubectl get pod "$POD_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.podIP}')
        if [ -n "$POD_IP" ]; then
            echo "Pod IP: $POD_IP"
            echo "Attempting to curl /ready endpoint..."
            kubectl run curl-test --image=curlimages/curl:latest --rm -i --restart=Never -- \
                curl -v -m 5 "http://${POD_IP}:8080/ready" 2>&1 || echo "Readiness endpoint test failed"
        fi
        echo ""
    else
        echo "ERROR: No pods found for deepagents-runtime!"
    fi
    
    echo "=== Checking Dependencies ==="
    echo "Database pods:"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime-db -o wide
    echo ""
    echo "Cache pods:"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime-cache -o wide
    echo ""
    
    echo "=== Checking Secrets ==="
    kubectl get secrets -n "${NAMESPACE}" | grep deepagents-runtime
    echo ""
    
    echo "Waiting for deployment to be ready..."
    if ! kubectl wait deployment/deepagents-runtime \
        -n "${NAMESPACE}" \
        --for=condition=Available \
        --timeout=300s; then
        
        log_error "Deployment failed to become ready within timeout!"
        echo ""
        echo "=== DEPLOYMENT FAILURE DIAGNOSTICS ==="
        echo ""
        
        # Get deployment status
        echo "--- Deployment Status ---"
        kubectl get deployment deepagents-runtime -n "${NAMESPACE}" -o wide
        echo ""
        kubectl describe deployment deepagents-runtime -n "${NAMESPACE}"
        echo ""
        
        # Get ReplicaSet status
        echo "--- ReplicaSet Status ---"
        kubectl get replicaset -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime -o wide
        echo ""
        kubectl describe replicaset -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime
        echo ""
        
        # Get pod status and logs
        echo "--- Pod Status ---"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime -o wide
        echo ""
        
        POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$POD_NAME" ]; then
            echo "--- Pod Description: $POD_NAME ---"
            kubectl describe pod "$POD_NAME" -n "${NAMESPACE}"
            echo ""
            
            echo "--- Pod Logs (Current) ---"
            kubectl logs "$POD_NAME" -n "${NAMESPACE}" --tail=100 || echo "No current logs available"
            echo ""
            
            echo "--- Pod Logs (Previous) ---"
            kubectl logs "$POD_NAME" -n "${NAMESPACE}" --previous --tail=100 || echo "No previous logs available"
            echo ""
            
            # Check container status
            echo "--- Container Status ---"
            kubectl get pod "$POD_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[*]}' | jq '.' || echo "Container status unavailable"
            echo ""
        else
            echo "ERROR: No pods found for deepagents-runtime!"
        fi
        
        # Get recent events
        echo "--- Recent Events ---"
        kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -30
        echo ""
        
        # Check dependencies
        echo "--- Dependency Status ---"
        echo "Database:"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime-db -o wide
        echo ""
        echo "Cache:"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime-cache -o wide
        echo ""
        
        # Check secrets
        echo "--- Secrets Status ---"
        kubectl get secrets -n "${NAMESPACE}" | grep deepagents-runtime
        echo ""
        
        # Node resources
        echo "--- Node Resources ---"
        kubectl describe nodes | grep -A 10 "Allocated resources:" || echo "Could not get node resources"
        echo ""
        
        log_error "Deployment diagnostics complete. Check logs above for details."
        exit 1
    fi
else
    echo "ERROR: Deployment 'deepagents-runtime' not found after 30 seconds!"
    echo "Checking EventDrivenService details..."
    kubectl describe eventdrivenservice deepagents-runtime -n "${NAMESPACE}" || echo "EventDrivenService not found"
    
    echo "Checking XEventDrivenService details..."
    kubectl get xeventdrivenservice -o yaml | grep -A 50 -B 10 deepagents || echo "No XEventDrivenService with deepagents found"
    
    echo "Checking Crossplane provider status..."
    kubectl get providers || echo "No providers found"
    
    echo "=== Final Resource Analysis ==="
    echo "=== Deployment Failure Diagnostics ==="
    echo "Run 'Cluster Diagnostics' step output for detailed service status"
    echo ""
    echo "EventDrivenService status:"
    kubectl describe eventdrivenservice deepagents-runtime -n "${NAMESPACE}" 2>/dev/null || echo "Not found"
    echo ""
    echo "Recent events in namespace:"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -15
    
    exit 1
fi

# Wait for pod to be ready
log_info "Waiting for pods to be ready..."
kubectl wait pod \
    -l app.kubernetes.io/name=deepagents-runtime \
    -n "${NAMESPACE}" \
    --for=condition=Ready \
    --timeout=300s

log_success "Service deployed successfully"
echo ""
echo "================================================================================"
echo "DEPLOYMENT SUMMARY"
echo "================================================================================"
echo "  Namespace:        ${NAMESPACE}"
echo "  Image:            ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Mode:             ${MODE}"
echo ""
echo "Service Status:"
kubectl get deployment,pods,svc -n "${NAMESPACE}" -l app.kubernetes.io/name=deepagents-runtime
echo ""
echo "Dependencies:"
kubectl get pods -n "${NAMESPACE}" -l 'app.kubernetes.io/name in (deepagents-runtime-db,deepagents-runtime-cache)'
echo ""
echo "To view logs:"
echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=deepagents-runtime -f"
echo ""
echo "To port-forward:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/deepagents-runtime 8080:8080"
echo "================================================================================"