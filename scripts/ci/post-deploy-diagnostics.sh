#!/bin/bash
set -euo pipefail

# ==============================================================================
# Post-Deploy Diagnostics Script
# ==============================================================================
# Purpose: Validate all service dependencies after deployment
# Usage: ./post-deploy-diagnostics.sh <namespace> <service-name>
# ==============================================================================

# Trap errors and show detailed information
trap 'echo ""; echo "ERROR: Script failed at line $LINENO with exit code $?"; echo "Last command: $BASH_COMMAND"; exit 1' ERR

NAMESPACE="${1:-intelligence-deepagents}"
SERVICE_NAME="${2:-deepagents-runtime}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

ERRORS=0
WARNINGS=0

check_failed() {
    ((ERRORS++))
    log_error "$1"
}

check_warning() {
    ((WARNINGS++))
    log_warning "$1"
}

check_passed() {
    log_success "$1"
}

echo "================================================================================"
echo "Service Diagnostics: ${SERVICE_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "================================================================================"
echo ""

# ==============================================================================
# 1. Check Service Deployment
# ==============================================================================
log_info "Checking service deployment..."

if ! kubectl get deployment "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    check_failed "Deployment '${SERVICE_NAME}' not found"
else
    DESIRED=$(kubectl get deployment "${SERVICE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')
    READY=$(kubectl get deployment "${SERVICE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
    AVAILABLE=$(kubectl get deployment "${SERVICE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.availableReplicas}')
    
    if [ "${READY:-0}" -eq "${DESIRED}" ] && [ "${AVAILABLE:-0}" -eq "${DESIRED}" ]; then
        check_passed "Deployment ready: ${READY}/${DESIRED} replicas"
    else
        check_failed "Deployment not ready: ${READY:-0}/${DESIRED} replicas ready, ${AVAILABLE:-0} available"
    fi
fi

# ==============================================================================
# 2. Check Pods
# ==============================================================================
log_info "Checking pods..."

POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${SERVICE_NAME}" --no-headers 2>/dev/null | wc -l)

if [ "${POD_COUNT}" -eq 0 ]; then
    check_failed "No pods found for service"
else
    check_passed "Found ${POD_COUNT} pod(s)"
    
    # Check each pod status
    while IFS= read -r line; do
        POD_NAME=$(echo "$line" | awk '{print $1}')
        POD_STATUS=$(echo "$line" | awk '{print $3}')
        POD_READY=$(echo "$line" | awk '{print $2}')
        
        if [ "$POD_STATUS" = "Running" ] && [[ "$POD_READY" == "1/1" ]]; then
            check_passed "Pod ${POD_NAME}: ${POD_STATUS} (${POD_READY})"
        else
            check_failed "Pod ${POD_NAME}: ${POD_STATUS} (${POD_READY})"
        fi
    done < <(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${SERVICE_NAME}" --no-headers 2>/dev/null)
fi

# ==============================================================================
# 3. Check Database (PostgreSQL)
# ==============================================================================
log_info "Checking PostgreSQL database..."

DB_NAME="${SERVICE_NAME}-db"
if ! kubectl get cluster "${DB_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    check_warning "PostgreSQL cluster '${DB_NAME}' not found (may use external DB)"
else
    DB_READY=$(kubectl get cluster "${DB_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.readyInstances}')
    DB_INSTANCES=$(kubectl get cluster "${DB_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.instances}')
    
    if [ "${DB_READY:-0}" -eq "${DB_INSTANCES:-0}" ] && [ "${DB_INSTANCES:-0}" -gt 0 ]; then
        check_passed "PostgreSQL ready: ${DB_READY}/${DB_INSTANCES} instances"
    else
        check_failed "PostgreSQL not ready: ${DB_READY:-0}/${DB_INSTANCES:-0} instances"
    fi
    
    # Check DB pods
    DB_POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l "cnpg.io/cluster=${DB_NAME}" --no-headers 2>/dev/null | wc -l)
    if [ "${DB_POD_COUNT}" -gt 0 ]; then
        check_passed "PostgreSQL has ${DB_POD_COUNT} pod(s) running"
    else
        check_failed "No PostgreSQL pods found"
    fi
fi

# Check DB connection secret (with wait/retry)
DB_SECRET="${SERVICE_NAME}-db-conn"
log_info "Checking database connection secret..."
if "${REPO_ROOT}/scripts/helpers/wait-for-secret.sh" "${DB_SECRET}" "${NAMESPACE}" 30 >/dev/null 2>&1; then
    check_passed "Database connection secret '${DB_SECRET}' exists"
else
    check_failed "Database connection secret '${DB_SECRET}' not found after 30s"
fi

# ==============================================================================
# 4. Check Cache (Dragonfly)
# ==============================================================================
log_info "Checking Dragonfly cache..."

CACHE_NAME="${SERVICE_NAME}-cache"
if ! kubectl get statefulset "${CACHE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    check_warning "Dragonfly StatefulSet '${CACHE_NAME}' not found (may use external cache)"
else
    CACHE_READY=$(kubectl get statefulset "${CACHE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
    CACHE_REPLICAS=$(kubectl get statefulset "${CACHE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')
    
    if [ "${CACHE_READY:-0}" -eq "${CACHE_REPLICAS:-0}" ]; then
        check_passed "Dragonfly ready: ${CACHE_READY}/${CACHE_REPLICAS} replicas"
    else
        check_failed "Dragonfly not ready: ${CACHE_READY:-0}/${CACHE_REPLICAS:-0} replicas"
    fi
    
    # Check cache pods (using label 'app' set by composition)
    log_info "Checking Dragonfly pods with label app=${CACHE_NAME}..."
    CACHE_POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l "app=${CACHE_NAME}" --no-headers 2>/dev/null | wc -l)
    if [ "${CACHE_POD_COUNT}" -gt 0 ]; then
        check_passed "Dragonfly has ${CACHE_POD_COUNT} pod(s) running"
    else
        check_failed "No Dragonfly pods found with label app=${CACHE_NAME}"
        echo "  Debugging: Listing all pods in namespace ${NAMESPACE}:"
        kubectl get pods -n "${NAMESPACE}" --show-labels 2>/dev/null || echo "  Could not list pods"
    fi
fi

# Check cache connection secret (with wait/retry)
CACHE_SECRET="${SERVICE_NAME}-cache-conn"
log_info "Checking cache connection secret (waiting up to 30s)..."
if "${REPO_ROOT}/scripts/helpers/wait-for-secret.sh" "${CACHE_SECRET}" "${NAMESPACE}" 30 2>&1 | grep -v "Waiting for secret"; then
    check_passed "Cache connection secret '${CACHE_SECRET}' exists"
else
    check_failed "Cache connection secret '${CACHE_SECRET}' not found after 30s"
    echo "  Debugging: Listing all secrets in namespace ${NAMESPACE}:"
    kubectl get secrets -n "${NAMESPACE}" 2>/dev/null | grep "${SERVICE_NAME}" || echo "  No matching secrets found"
fi

# ==============================================================================
# 5. Check NATS Infrastructure
# ==============================================================================
log_info "Checking NATS infrastructure..."

# Check NATS server
if ! kubectl get pods -n nats -l app.kubernetes.io/name=nats --no-headers 2>/dev/null | grep -q Running; then
    check_failed "NATS server not running in 'nats' namespace"
else
    check_passed "NATS server is running"
fi

# Check NATS service
if kubectl get svc nats -n nats >/dev/null 2>&1; then
    check_passed "NATS service exists at nats.nats.svc:4222"
else
    check_failed "NATS service not found"
fi

# ==============================================================================
# 6. Check NATS Stream and Consumer
# ==============================================================================
log_info "Checking NATS stream and consumer..."

# Debug: Show all pods in nats namespace first
log_info "DEBUG: Listing all pods in nats namespace..."
kubectl get pods -n nats -o wide 2>&1 || echo "  Failed to list pods"

# Try to get stream info using nats-box if available
# Disable exit on error for entire NATS section
set +e
NATS_BOX_CHECK=$(kubectl get pod -n nats -l app=nats-box --no-headers 2>&1)
NATS_BOX_EXIT=$?
log_info "DEBUG: nats-box check exit code: ${NATS_BOX_EXIT}"
log_info "DEBUG: nats-box check output: ${NATS_BOX_CHECK}"

if [ $NATS_BOX_EXIT -eq 0 ] && echo "$NATS_BOX_CHECK" | grep -q Running; then
    NATS_BOX_POD=$(kubectl get pod -n nats -l app=nats-box -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$NATS_BOX_POD" ]; then
        check_warning "nats-box pod not found, skipping stream validation"
    else
        log_info "Using nats-box pod: ${NATS_BOX_POD}"
        
        # Check if stream exists
        STREAM_CHECK=$(kubectl exec -n nats "${NATS_BOX_POD}" -- nats stream info AGENT_EXECUTION --server=nats://nats.nats.svc:4222 2>&1)
        STREAM_EXIT_CODE=$?
        log_info "DEBUG: Stream check exit code: ${STREAM_EXIT_CODE}"
        
        if [ $STREAM_EXIT_CODE -eq 0 ]; then
            check_passed "NATS stream 'AGENT_EXECUTION' exists"
            
            # Get stream details
            STREAM_MSGS=$(echo "$STREAM_CHECK" | grep -o '"messages":[0-9]*' | cut -d: -f2 || echo "0")
            check_passed "Stream has ${STREAM_MSGS} message(s)"
        else
            check_failed "NATS stream 'AGENT_EXECUTION' not found"
            echo "  Error output: ${STREAM_CHECK}"
        fi
        
        # Check if consumer exists
        CONSUMER_CHECK=$(kubectl exec -n nats "${NATS_BOX_POD}" -- nats consumer info AGENT_EXECUTION "${SERVICE_NAME}-workers" --server=nats://nats.nats.svc:4222 2>&1)
        CONSUMER_EXIT_CODE=$?
        log_info "DEBUG: Consumer check exit code: ${CONSUMER_EXIT_CODE}"
        
        if [ $CONSUMER_EXIT_CODE -eq 0 ]; then
            check_passed "NATS consumer '${SERVICE_NAME}-workers' exists"
        else
            check_failed "NATS consumer '${SERVICE_NAME}-workers' not found"
            echo "  Error output: ${CONSUMER_CHECK}"
        fi
    fi
else
    check_warning "nats-box not available or not running, skipping stream validation"
fi
# Re-enable exit on error after NATS section
set -e

# ==============================================================================
# 7. Check Secrets
# ==============================================================================
log_info "Checking application secrets..."

# Check LLM keys secret (with wait/retry)
LLM_SECRET="${SERVICE_NAME}-llm-keys"
log_info "Checking LLM keys secret..."
if "${REPO_ROOT}/scripts/helpers/wait-for-secret.sh" "${LLM_SECRET}" "${NAMESPACE}" 30 >/dev/null 2>&1; then
    check_passed "LLM keys secret '${LLM_SECRET}' exists"
    
    # Verify it has required keys
    if kubectl get secret "${LLM_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.OPENAI_API_KEY}' | grep -q .; then
        check_passed "OPENAI_API_KEY present in secret"
    else
        check_failed "OPENAI_API_KEY missing from secret"
    fi
    
    if kubectl get secret "${LLM_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.ANTHROPIC_API_KEY}' | grep -q .; then
        check_passed "ANTHROPIC_API_KEY present in secret"
    else
        check_failed "ANTHROPIC_API_KEY missing from secret"
    fi
else
    check_failed "LLM keys secret '${LLM_SECRET}' not found after 30s"
fi

# ==============================================================================
# 8. Check Service Endpoint
# ==============================================================================
log_info "Checking service endpoint..."

if kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    check_passed "Service '${SERVICE_NAME}' exists"
    
    SVC_PORT=$(kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].port}')
    check_passed "Service exposed on port ${SVC_PORT}"
else
    check_failed "Service '${SERVICE_NAME}' not found"
fi

# ==============================================================================
# 9. Check Service Health
# ==============================================================================
log_info "Checking service health endpoints..."

POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${SERVICE_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD_NAME}" ]; then
    # Check health endpoint
    if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        check_passed "Health endpoint responding"
    else
        check_warning "Health endpoint not responding (may still be starting)"
    fi
    
    # Check readiness endpoint
    if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- curl -sf http://localhost:8080/ready >/dev/null 2>&1; then
        check_passed "Readiness endpoint responding"
    else
        check_failed "Readiness endpoint not responding"
        
        # Get readiness response for debugging
        READY_RESPONSE=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- curl -s http://localhost:8080/ready 2>/dev/null || echo "")
        if [ -n "${READY_RESPONSE}" ]; then
            echo "  Response: ${READY_RESPONSE}"
        fi
    fi
fi

# ==============================================================================
# 10. Check KEDA ScaledObject
# ==============================================================================
log_info "Checking KEDA autoscaling..."

SCALER_NAME="${SERVICE_NAME}-scaler"
if kubectl get scaledobject "${SCALER_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    check_passed "KEDA ScaledObject '${SCALER_NAME}' exists"
    
    SCALER_READY=$(kubectl get scaledobject "${SCALER_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "${SCALER_READY}" = "True" ]; then
        check_passed "ScaledObject is ready"
    else
        check_warning "ScaledObject not ready yet"
    fi
else
    check_warning "KEDA ScaledObject '${SCALER_NAME}' not found (may not use autoscaling)"
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "================================================================================"
echo "Diagnostics Summary"
echo "================================================================================"
echo -e "Checks passed: ${GREEN}$(( $(grep -c "✓" <<< "$(declare -f)" || echo 0) ))${NC}"
echo -e "Warnings:      ${YELLOW}${WARNINGS}${NC}"
echo -e "Errors:        ${RED}${ERRORS}${NC}"
echo "================================================================================"
echo ""

if [ "${ERRORS}" -gt 0 ]; then
    log_error "Service has ${ERRORS} error(s). Not ready for integration tests."
    exit 1
elif [ "${WARNINGS}" -gt 0 ]; then
    log_warning "Service has ${WARNINGS} warning(s) but is functional."
    exit 0
else
    log_success "All checks passed! Service is ready for integration tests."
    exit 0
fi
