#!/bin/bash
# Validate Platform Dependencies
# Usage: ./validate-platform-dependencies.sh
#
# Quick validation that required platform services exist before deploying claims.
# Does NOT wait - assumes platform is already ready.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "================================================================================"
echo "Validating Platform Dependencies"
echo "================================================================================"

# Check required XRDs exist
log_info "Checking required XRDs..."
required_xrds=(
    "xeventdrivenservices.platform.bizmatters.io"
    "xpostgresinstances.database.bizmatters.io"
    "xdragonflyinstances.database.bizmatters.io"
)

for xrd in "${required_xrds[@]}"; do
    if kubectl get xrd "$xrd" >/dev/null 2>&1; then
        log_success "✓ XRD $xrd exists"
    else
        log_error "✗ XRD $xrd not found"
        exit 1
    fi
done

# Check required compositions exist
log_info "Checking required compositions..."
required_compositions=(
    "event-driven-service"
    "postgres-instance"
    "dragonfly-instance"
)

for comp in "${required_compositions[@]}"; do
    if kubectl get composition "$comp" >/dev/null 2>&1; then
        log_success "✓ Composition $comp exists"
    else
        log_error "✗ Composition $comp not found"
        exit 1
    fi
done

# Check Crossplane providers are ready
log_info "Checking Crossplane providers..."
if ! kubectl get providers >/dev/null 2>&1; then
    log_error "✗ No Crossplane providers found"
    exit 1
fi

healthy_providers=$(kubectl get providers -o json | jq -r '[.items[] | select(.status.conditions[] | select(.type=="Healthy" and .status=="True"))] | length')
total_providers=$(kubectl get providers --no-headers | wc -l)

if [ "$healthy_providers" -eq "$total_providers" ]; then
    log_success "✓ All $total_providers Crossplane providers are healthy"
else
    log_warn "⚠ Only $healthy_providers/$total_providers providers are healthy"
    # Don't fail - providers might still be starting
fi

# Check core platform namespaces exist
log_info "Checking core platform namespaces..."
required_namespaces=(
    "crossplane-system"
    "external-secrets"
    "argocd"
)

for ns in "${required_namespaces[@]}"; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_success "✓ Namespace $ns exists"
    else
        log_error "✗ Namespace $ns not found"
        exit 1
    fi
done

# Quick connectivity check to core services (if they exist)
log_info "Checking service endpoints..."

# Check if postgres clusters exist and are reachable
if kubectl get clusters.postgresql.cnpg.io --all-namespaces >/dev/null 2>&1; then
    pg_count=$(kubectl get clusters.postgresql.cnpg.io --all-namespaces --no-headers | wc -l)
    log_success "✓ Found $pg_count PostgreSQL clusters"
fi

# Check if dragonfly caches exist
if kubectl get statefulsets --all-namespaces -l app=dragonfly >/dev/null 2>&1; then
    df_count=$(kubectl get statefulsets --all-namespaces -l app=dragonfly --no-headers | wc -l)
    log_success "✓ Found $df_count Dragonfly caches"
fi

# Check if NATS exists
if kubectl get statefulset nats -n nats >/dev/null 2>&1; then
    log_success "✓ Found NATS messaging"
fi

# Check External Secrets Operator
if kubectl get clustersecretstore aws-parameter-store >/dev/null 2>&1; then
    store_status=$(kubectl get clustersecretstore aws-parameter-store -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "Unknown")
    if [ "$store_status" = "True" ]; then
        log_success "✓ External Secrets ClusterSecretStore is ready"
    else
        log_warn "⚠ External Secrets ClusterSecretStore status: $store_status"
    fi
fi

echo ""
log_success "Platform dependency validation completed successfully"
echo "================================================================================"