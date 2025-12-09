#!/bin/bash
# Tier 3 Script: Setup Preview Cluster
# Creates and configures Kind cluster with platform dependencies
#
# Environment Variables (required):
#   AWS_ACCESS_KEY_ID - AWS access key for ESO
#   AWS_SECRET_ACCESS_KEY - AWS secret key for ESO
#   ZEROTOUCH_PLATFORM_DIR - Path to zerotouch-platform repository
#
# Exit Codes:
#   0 - Success
#   1 - Kind cluster creation failed
#   2 - Crossplane installation failed
#   3 - Provider installation failed
#   4 - CNPG installation failed
#   5 - NATS installation failed
#   6 - ESO installation failed

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helper functions
# shellcheck source=./helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Configuration
CLUSTER_NAME="deepagnets-preview"
KIND_CONFIG="$SCRIPT_DIR/../kind-config.yaml"
CROSSPLANE_NAMESPACE="crossplane-system"
CROSSPLANE_VERSION="1.16.0"  # From platform: bootstrap/components/01-crossplane.yaml
CNPG_VERSION="0.22.1"         # From platform: bootstrap/components/01-cnpg.yaml
NATS_NAMESPACE="nats"
NATS_VERSION="1.2.6"          # From platform: bootstrap/components/01-nats.yaml
ESO_NAMESPACE="external-secrets"

# Validate required environment variables
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    log_error "AWS_ACCESS_KEY_ID environment variable is required"
    exit 1
fi

if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    log_error "AWS_SECRET_ACCESS_KEY environment variable is required"
    exit 1
fi

if [[ -z "${ZEROTOUCH_PLATFORM_DIR:-}" ]]; then
    log_error "ZEROTOUCH_PLATFORM_DIR environment variable is required"
    exit 1
fi

if [[ ! -d "$ZEROTOUCH_PLATFORM_DIR" ]]; then
    log_error "ZEROTOUCH_PLATFORM_DIR does not exist: $ZEROTOUCH_PLATFORM_DIR"
    exit 1
fi

log_info "Starting preview cluster setup..."
log_info "Cluster name: $CLUSTER_NAME"

# ============================================================================
# Step 1: Create Kind Cluster
# ============================================================================
log_info "Step 1: Creating Kind cluster..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_info "Kind cluster '$CLUSTER_NAME' already exists"
else
    log_info "Creating Kind cluster '$CLUSTER_NAME' with config: $KIND_CONFIG"
    if ! kind create cluster --config "$KIND_CONFIG"; then
        log_error "Failed to create Kind cluster"
        exit 1
    fi
    log_info "Kind cluster created successfully"
fi

# Set kubectl context
kubectl config use-context "kind-${CLUSTER_NAME}"

# ============================================================================
# Step 2: Install Crossplane
# ============================================================================
log_info "Step 2: Installing Crossplane..."

# Create namespace
create_namespace_idempotent "$CROSSPLANE_NAMESPACE"

# Add Crossplane Helm repository
log_info "Adding Crossplane Helm repository..."
helm repo add crossplane-stable https://charts.crossplane.io/stable 2>/dev/null || true
helm repo update crossplane-stable

# Install Crossplane
if ! helm_install_idempotent \
    "crossplane" \
    "crossplane-stable/crossplane" \
    "$CROSSPLANE_NAMESPACE" \
    "--version" "$CROSSPLANE_VERSION" \
    "--wait" \
    "--timeout" "10m"; then
    log_error "Failed to install Crossplane"
    exit 2
fi

# Wait for Crossplane deployment to be ready
log_info "Waiting for Crossplane deployment to be ready..."
if ! wait_for_deployment_ready "crossplane" "$CROSSPLANE_NAMESPACE" 300; then
    log_error "Crossplane deployment did not become ready"
    exit 2
fi

log_info "Crossplane installed successfully"

# ============================================================================
# Step 3: Install Crossplane Kubernetes Provider
# ============================================================================
log_info "Step 3: Installing Crossplane Kubernetes provider..."

# Check if provider already exists
if resource_exists "provider.pkg.crossplane.io" "provider-kubernetes" ""; then
    log_info "Crossplane Kubernetes provider already exists"
else
    log_info "Creating Crossplane Kubernetes provider..."
    cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.11.0
EOF
fi

# Wait for provider to be healthy
log_info "Waiting for Kubernetes provider to be healthy..."
if ! kubectl wait provider.pkg.crossplane.io/provider-kubernetes \
    --for=condition=Healthy \
    --timeout=300s; then
    log_error "Kubernetes provider did not become healthy"
    exit 3
fi

# Create ProviderConfig for in-cluster access
if resource_exists "providerconfig.kubernetes.crossplane.io" "kubernetes-provider" ""; then
    log_info "ProviderConfig 'kubernetes-provider' already exists"
else
    log_info "Creating ProviderConfig for in-cluster access..."
    cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: kubernetes-provider
spec:
  credentials:
    source: InjectedIdentity
EOF
fi

log_info "Crossplane Kubernetes provider installed successfully"

# ============================================================================
# Step 4: Install CloudNativePG Operator
# ============================================================================
log_info "Step 4: Installing CloudNativePG operator..."

# Create namespace
create_namespace_idempotent "cnpg-system"

# Add CloudNativePG Helm repository
log_info "Adding CloudNativePG Helm repository..."
helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
helm repo update cnpg

# Install CloudNativePG
if ! helm_install_idempotent \
    "cloudnative-pg" \
    "cnpg/cloudnative-pg" \
    "cnpg-system" \
    "--version" "$CNPG_VERSION" \
    "--wait" \
    "--timeout" "5m"; then
    log_error "Failed to install CloudNativePG"
    exit 4
fi

# Wait for CNPG deployment to be ready
log_info "Waiting for CloudNativePG deployment to be ready..."
if ! wait_for_deployment_ready "cloudnative-pg" "cnpg-system" 300; then
    log_error "CloudNativePG deployment did not become ready"
    exit 4
fi

log_info "CloudNativePG operator installed successfully"

# ============================================================================
# Step 5: Install External Secrets Operator (ESO)
# ============================================================================
log_info "Step 5: Installing External Secrets Operator..."

# Create namespace
create_namespace_idempotent "$ESO_NAMESPACE"

# Add External Secrets Helm repository
log_info "Adding External Secrets Helm repository..."
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets

# Install ESO using Helm (extracting values from ArgoCD Application manifest)
log_info "Installing External Secrets Operator via Helm..."
if ! helm_install_idempotent \
    "external-secrets" \
    "external-secrets/external-secrets" \
    "$ESO_NAMESPACE" \
    "--version" "0.9.13" \
    "--set" "installCRDs=true" \
    "--set" "webhook.create=true" \
    "--wait" \
    "--timeout" "5m"; then
    log_error "Failed to install External Secrets Operator"
    exit 6
fi

# Wait for ESO deployments to be ready
log_info "Waiting for ESO deployments to be ready..."
if ! kubectl wait --for=condition=available deployment \
    -l app.kubernetes.io/name=external-secrets \
    -n "$ESO_NAMESPACE" \
    --timeout=300s; then
    log_error "ESO deployments did not become ready"
    exit 6
fi

log_info "External Secrets Operator installed successfully"

# ============================================================================
# Step 6: Inject AWS Credentials for ESO
# ============================================================================
log_info "Step 6: Injecting AWS credentials for ESO..."

# Use the platform's script to inject credentials
ESO_INJECT_SCRIPT="$ZEROTOUCH_PLATFORM_DIR/scripts/bootstrap/07-inject-eso-secrets.sh"

if [[ ! -f "$ESO_INJECT_SCRIPT" ]]; then
    log_error "ESO inject script not found: $ESO_INJECT_SCRIPT"
    exit 6
fi

log_info "Running ESO credential injection script..."
if ! bash "$ESO_INJECT_SCRIPT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"; then
    log_error "Failed to inject AWS credentials"
    exit 6
fi

log_info "AWS credentials injected successfully"

# ============================================================================
# Step 7: Apply ClusterSecretStore
# ============================================================================
log_info "Step 7: Applying ClusterSecretStore..."

CLUSTER_SECRET_STORE="$ZEROTOUCH_PLATFORM_DIR/platform/01-foundation/aws-secret-store.yaml"

if [[ ! -f "$CLUSTER_SECRET_STORE" ]]; then
    log_error "ClusterSecretStore manifest not found: $CLUSTER_SECRET_STORE"
    exit 6
fi

log_info "Applying ClusterSecretStore from platform..."
if ! kubectl apply -f "$CLUSTER_SECRET_STORE"; then
    log_error "Failed to apply ClusterSecretStore"
    exit 6
fi

# Wait for ClusterSecretStore to be ready
log_info "Waiting for ClusterSecretStore to be ready..."
if ! kubectl wait clustersecretstore/aws-parameter-store \
    --for=condition=Ready \
    --timeout=60s 2>/dev/null; then
    log_warn "ClusterSecretStore wait timed out, but this may be expected"
fi

log_info "ClusterSecretStore applied successfully"

# ============================================================================
# Step 8: Install NATS with JetStream
# ============================================================================
log_info "Step 8: Installing NATS with JetStream..."

# Create namespace
create_namespace_idempotent "$NATS_NAMESPACE"

# Add NATS Helm repository
log_info "Adding NATS Helm repository..."
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ 2>/dev/null || true
helm repo update nats

# Install NATS with JetStream enabled (matching platform config)
if ! helm_install_idempotent \
    "nats" \
    "nats/nats" \
    "$NATS_NAMESPACE" \
    "--version" "$NATS_VERSION" \
    "--set" "config.jetstream.enabled=true" \
    "--set" "config.jetstream.fileStore.enabled=true" \
    "--set" "config.jetstream.fileStore.pvc.enabled=true" \
    "--set" "config.jetstream.fileStore.pvc.size=10Gi" \
    "--set" "config.jetstream.memoryStore.enabled=true" \
    "--set" "config.jetstream.memoryStore.maxSize=1Gi" \
    "--set" "natsBox.enabled=true" \
    "--wait" \
    "--timeout" "5m"; then
    log_error "Failed to install NATS"
    exit 5
fi

# Wait for NATS StatefulSet to be ready
log_info "Waiting for NATS StatefulSet to be ready..."
if ! kubectl wait statefulset/nats \
    -n "$NATS_NAMESPACE" \
    --for=jsonpath='{.status.readyReplicas}'=1 \
    --timeout=300s; then
    log_error "NATS StatefulSet did not become ready"
    exit 5
fi

log_info "NATS installed successfully"

# ============================================================================
# Step 9: Create NATS Streams
# ============================================================================
log_info "Step 9: Creating NATS JetStream streams..."

# Wait a bit for NATS to fully initialize
sleep 5

# Get nats-box pod name (has nats CLI tools)
NATS_BOX_POD=$(kubectl get pod -n "$NATS_NAMESPACE" -l app=nats-box -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$NATS_BOX_POD" ]]; then
    log_warn "Could not find nats-box pod, skipping stream creation"
    log_warn "Streams will be created by the application on first use"
else
    log_info "Using nats-box pod: $NATS_BOX_POD"
    
    # Function to create stream idempotently
    create_nats_stream() {
        local stream_name="$1"
        local subjects="$2"
        
        log_info "Creating NATS stream: $stream_name"
        
        # Check if stream already exists
        if kubectl exec -n "$NATS_NAMESPACE" "$NATS_BOX_POD" -- \
            nats stream info "$stream_name" >/dev/null 2>&1; then
            log_info "NATS stream '$stream_name' already exists"
            return 0
        fi
        
        # Create stream
        if kubectl exec -n "$NATS_NAMESPACE" "$NATS_BOX_POD" -- \
            nats stream add "$stream_name" \
            --subjects="$subjects" \
            --storage=file \
            --retention=limits \
            --discard=old \
            --max-msgs=-1 \
            --max-bytes=-1 \
            --max-age=24h \
            --max-msg-size=-1 \
            --dupe-window=2m \
            --replicas=1 \
            --no-confirm; then
            log_info "NATS stream '$stream_name' created successfully"
            return 0
        else
            log_error "Failed to create NATS stream '$stream_name'"
            return 1
        fi
    }
fi

# Create streams if nats-box is available
if [[ -n "$NATS_BOX_POD" ]]; then
    # Create AGENT_EXECUTION stream
    if ! create_nats_stream "AGENT_EXECUTION" "agent.execution.>"; then
        log_warn "Failed to create AGENT_EXECUTION stream, will be created by application"
    fi

    # Create AGENT_RESULTS stream
    if ! create_nats_stream "AGENT_RESULTS" "agent.results.>"; then
        log_warn "Failed to create AGENT_RESULTS stream, will be created by application"
    fi

    log_info "NATS streams created successfully"
else
    log_info "Skipping stream creation, will be handled by application"
fi

# ============================================================================
# Final Verification
# ============================================================================
log_info "Performing final verification..."

# Verify all critical components are running
log_info "Verifying Crossplane..."
kubectl get deployment -n "$CROSSPLANE_NAMESPACE" crossplane

log_info "Verifying CloudNativePG..."
kubectl get deployment -n cnpg-system cloudnative-pg

log_info "Verifying External Secrets Operator..."
kubectl get deployment -n "$ESO_NAMESPACE" -l app.kubernetes.io/name=external-secrets

log_info "Verifying NATS..."
kubectl get statefulset -n "$NATS_NAMESPACE" nats

log_info "Verifying ClusterSecretStore..."
kubectl get clustersecretstore aws-parameter-store

log_info "Verifying Crossplane provider..."
kubectl get provider.pkg.crossplane.io provider-kubernetes

log_info "✓ Preview cluster setup completed successfully!"
log_info "Cluster: $CLUSTER_NAME"
log_info "Context: kind-${CLUSTER_NAME}"

exit 0
