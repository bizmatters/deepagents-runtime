#!/bin/bash
# Tier 3 Script: Deploy Service
# Deploys deepagents-runtime using platform claims
#
# Environment Variables (required):
#   AWS_ACCESS_KEY_ID - AWS access key for ESO (inherited from setup)
#   AWS_SECRET_ACCESS_KEY - AWS secret key for ESO (inherited from setup)
#
# Exit Codes:
#   0 - Success
#   1 - Image build failed
#   2 - Claim application failed
#   3 - Resource creation failed
#   4 - Pod not ready

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source helper functions
# shellcheck source=./helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Configuration
NAMESPACE="intelligence-deepagents"
IMAGE_NAME="agent-executor"
IMAGE_TAG="ci-test"
CLUSTER_NAME="deepagnets-preview"
CLAIMS_DIR="$REPO_ROOT/platform/claims/intelligence-deepagents"
EXTERNAL_SECRETS_DIR="$CLAIMS_DIR/external-secrets"

log_info "Starting service deployment..."
log_info "Repository root: $REPO_ROOT"
log_info "Claims directory: $CLAIMS_DIR"

# Validate claims directory exists
if [[ ! -d "$CLAIMS_DIR" ]]; then
    log_error "Claims directory not found: $CLAIMS_DIR"
    exit 2
fi

# ============================================================================
# Step 1: Build Docker Image
# ============================================================================
log_info "Step 1: Building Docker image..."

log_info "Building image: ${IMAGE_NAME}:${IMAGE_TAG}"
if ! docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$REPO_ROOT"; then
    log_error "Failed to build Docker image"
    exit 1
fi

log_info "Docker image built successfully"

# ============================================================================
# Step 2: Load Image into Kind Cluster
# ============================================================================
log_info "Step 2: Loading image into Kind cluster..."

log_info "Loading image into cluster: $CLUSTER_NAME"
if ! kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "$CLUSTER_NAME"; then
    log_error "Failed to load image into Kind cluster"
    exit 1
fi

log_info "Image loaded successfully into Kind cluster"

# ============================================================================
# Step 3: Create Namespace
# ============================================================================
log_info "Step 3: Creating namespace..."

if ! create_namespace_idempotent "$NAMESPACE"; then
    log_error "Failed to create namespace"
    exit 2
fi

log_info "Namespace ready"

# ============================================================================
# Step 4: Apply ExternalSecret for LLM Keys
# ============================================================================
log_info "Step 4: Applying ExternalSecret for LLM keys..."

LLM_KEYS_ES="$EXTERNAL_SECRETS_DIR/llm-keys-es.yaml"

if [[ ! -f "$LLM_KEYS_ES" ]]; then
    log_error "LLM keys ExternalSecret not found: $LLM_KEYS_ES"
    exit 2
fi

log_info "Applying ExternalSecret: llm-keys-es.yaml"
if ! kubectl apply -f "$LLM_KEYS_ES"; then
    log_error "Failed to apply ExternalSecret"
    exit 2
fi

# Wait for ExternalSecret to sync
log_info "Waiting for ExternalSecret to sync (timeout: 120s)..."
if ! kubectl wait externalsecret/agent-executor-llm-keys \
    -n "$NAMESPACE" \
    --for=condition=Ready \
    --timeout=120s 2>/dev/null; then
    log_warn "ExternalSecret wait timed out, checking status..."
    log_warn "ExternalSecret status:"
    kubectl get externalsecret -n "$NAMESPACE" agent-executor-llm-keys -o yaml || true
    log_warn "Checking ClusterSecretStore:"
    kubectl get clustersecretstore aws-parameter-store -o yaml || true
    log_warn "Checking AWS credentials secret:"
    kubectl get secret -n external-secrets aws-access-token || true
    log_warn "Checking ESO pod logs:"
    kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=50 || true
fi

# Wait for the Kubernetes secret to be created
log_info "Waiting for Kubernetes secret to be created..."
RETRY_COUNT=0
MAX_RETRIES=30
while ! resource_exists "secret" "agent-executor-llm-keys" "$NAMESPACE"; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
        log_error "Timeout waiting for secret agent-executor-llm-keys to be created"
        kubectl get externalsecret -n "$NAMESPACE" agent-executor-llm-keys -o yaml || true
        exit 2
    fi
    log_info "Waiting for secret... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

log_info "Secret agent-executor-llm-keys created successfully"

# ============================================================================
# Step 5: Apply Claims in Sync-Wave Order
# ============================================================================
log_info "Step 5: Applying claims in sync-wave order..."

# Sync-wave 0: Database claims
log_info "Applying sync-wave 0 claims (databases)..."

POSTGRES_CLAIM="$CLAIMS_DIR/postgres-claim.yaml"
DRAGONFLY_CLAIM="$CLAIMS_DIR/dragonfly-claim.yaml"

if [[ ! -f "$POSTGRES_CLAIM" ]]; then
    log_error "PostgreSQL claim not found: $POSTGRES_CLAIM"
    exit 2
fi

if [[ ! -f "$DRAGONFLY_CLAIM" ]]; then
    log_error "Dragonfly claim not found: $DRAGONFLY_CLAIM"
    exit 2
fi

log_info "Applying PostgreSQL claim..."
if ! kubectl apply -f "$POSTGRES_CLAIM"; then
    log_error "Failed to apply PostgreSQL claim"
    exit 2
fi

log_info "Applying Dragonfly claim..."
if ! kubectl apply -f "$DRAGONFLY_CLAIM"; then
    log_error "Failed to apply Dragonfly claim"
    exit 2
fi

log_info "Database claims applied successfully"

# ============================================================================
# Step 6: Wait for Database Connection Secrets
# ============================================================================
log_info "Step 6: Waiting for database connection secrets..."

# Wait for PostgreSQL connection secret
log_info "Waiting for PostgreSQL connection secret..."
RETRY_COUNT=0
MAX_RETRIES=60
while ! resource_exists "secret" "agent-executor-db-conn" "$NAMESPACE"; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
        log_error "Timeout waiting for PostgreSQL connection secret"
        kubectl get postgresinstance -n "$NAMESPACE" agent-executor-db -o yaml || true
        exit 3
    fi
    log_info "Waiting for PostgreSQL secret... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 5
done

log_info "PostgreSQL connection secret created"

# Wait for Dragonfly connection secret
log_info "Waiting for Dragonfly connection secret..."
RETRY_COUNT=0
MAX_RETRIES=60
while ! resource_exists "secret" "agent-executor-cache-conn" "$NAMESPACE"; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
        log_error "Timeout waiting for Dragonfly connection secret"
        kubectl get dragonflyinstance -n "$NAMESPACE" agent-executor-cache -o yaml || true
        exit 3
    fi
    log_info "Waiting for Dragonfly secret... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 5
done

log_info "Dragonfly connection secret created"
log_info "All database connection secrets ready"

# ============================================================================
# Step 7: Apply EventDrivenService Claim (Sync-wave 2)
# ============================================================================
log_info "Step 7: Applying EventDrivenService claim..."

DEPLOYMENT_CLAIM="$CLAIMS_DIR/agent-executor-deployment.yaml"

if [[ ! -f "$DEPLOYMENT_CLAIM" ]]; then
    log_error "EventDrivenService claim not found: $DEPLOYMENT_CLAIM"
    exit 2
fi

# Patch the image reference to use our CI-built image
log_info "Patching EventDrivenService claim to use CI image..."
TEMP_CLAIM=$(mktemp)
sed "s|image: ghcr.io/arun4infra/agent-executor:latest|image: ${IMAGE_NAME}:${IMAGE_TAG}|g" \
    "$DEPLOYMENT_CLAIM" > "$TEMP_CLAIM"

# Also remove imagePullSecrets since we're using a local image
sed -i.bak '/imagePullSecrets:/,+1d' "$TEMP_CLAIM"

log_info "Applying patched EventDrivenService claim..."
if ! kubectl apply -f "$TEMP_CLAIM"; then
    log_error "Failed to apply EventDrivenService claim"
    rm -f "$TEMP_CLAIM" "$TEMP_CLAIM.bak"
    exit 2
fi

rm -f "$TEMP_CLAIM" "$TEMP_CLAIM.bak"
log_info "EventDrivenService claim applied successfully"

# ============================================================================
# Step 8: Wait for Deployment to be Created
# ============================================================================
log_info "Step 8: Waiting for Deployment to be created..."

RETRY_COUNT=0
MAX_RETRIES=30
while ! resource_exists "deployment" "deepagents-runtime" "$NAMESPACE"; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
        log_error "Timeout waiting for Deployment to be created"
        kubectl get eventdrivenservice -n "$NAMESPACE" agent-executor -o yaml || true
        exit 3
    fi
    log_info "Waiting for Deployment... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

log_info "Deployment created"

# ============================================================================
# Step 9: Wait for Pod to be Ready
# ============================================================================
log_info "Step 9: Waiting for agent-executor pod to be ready..."

log_info "Waiting for pod with label app.kubernetes.io/name=deepagents-runtime..."
if ! kubectl wait pod \
    -l app.kubernetes.io/name=deepagents-runtime \
    -n "$NAMESPACE" \
    --for=condition=Ready \
    --timeout=600s; then
    log_error "Pod did not become ready within timeout"
    log_error "Pod status:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=deepagents-runtime || true
    log_error "Pod logs:"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=deepagents-runtime --tail=50 || true
    log_error "Pod events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
    exit 4
fi

log_info "Pod is ready"

# ============================================================================
# Step 10: Verify All Resources
# ============================================================================
log_info "Step 10: Verifying all resources..."

# Verify namespace
log_info "Verifying namespace..."
kubectl get namespace "$NAMESPACE"

# Verify secrets
log_info "Verifying secrets..."
kubectl get secret -n "$NAMESPACE" agent-executor-llm-keys
kubectl get secret -n "$NAMESPACE" agent-executor-db-conn
kubectl get secret -n "$NAMESPACE" agent-executor-cache-conn

# Verify claims
log_info "Verifying Crossplane claims..."
kubectl get postgresinstance -n "$NAMESPACE" agent-executor-db
kubectl get dragonflyinstance -n "$NAMESPACE" agent-executor-cache
kubectl get eventdrivenservice -n "$NAMESPACE" agent-executor

# Verify deployment
log_info "Verifying deployment..."
kubectl get deployment -n "$NAMESPACE" deepagents-runtime

# Verify pod
log_info "Verifying pod..."
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=deepagents-runtime

# Verify KEDA ScaledObject if it exists
log_info "Verifying KEDA ScaledObject..."
if kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1; then
    kubectl get scaledobject -n "$NAMESPACE" 2>/dev/null || log_warn "No KEDA ScaledObjects found"
fi

log_info "✓ Service deployment completed successfully!"
log_info "Namespace: $NAMESPACE"
log_info "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
log_info "Pod: $(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=deepagents-runtime -o jsonpath='{.items[0].metadata.name}')"

exit 0
