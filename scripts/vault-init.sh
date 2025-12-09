#!/usr/bin/env bash

################################################################################
# vault-init.sh
#
# Purpose: Initialize and configure HashiCorp Vault for agent_executor service
#
# Prerequisites:
#   - Vault server running and accessible (VAULT_ADDR set)
#   - Vault CLI installed (vault command available)
#   - Vault unsealed and root token available (for initial setup)
#   - kubectl configured (for K8s integration)
#
# Usage:
#   # Set Vault address and token
#   export VAULT_ADDR="http://localhost:8200"
#   export VAULT_TOKEN="your-root-token"
#
#   # Run initialization
#   ./vault-init.sh
#
# Features:
#   - Idempotent: Safe to re-run multiple times
#   - Creates KV v2 secrets engine at secret/agent-executor
#   - Configures policy for agent_executor service
#   - Sets up Kubernetes auth method (if K8s is available)
#   - Enables AppRole auth method for local development
#
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SECRETS_PATH="secret/agent-executor"
POLICY_NAME="agent-executor-policy"
APPROLE_NAME="agent-executor"
K8S_ROLE_NAME="agent-executor"
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-agent-executor}"

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if vault CLI exists
    if ! command -v vault &> /dev/null; then
        log_error "vault CLI not found. Please install HashiCorp Vault."
        exit 1
    fi

    # Check if VAULT_ADDR is set
    if [[ -z "${VAULT_ADDR:-}" ]]; then
        log_error "VAULT_ADDR environment variable not set."
        log_error "Example: export VAULT_ADDR='http://localhost:8200'"
        exit 1
    fi

    # Check if VAULT_TOKEN is set
    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        log_error "VAULT_TOKEN environment variable not set."
        log_error "Example: export VAULT_TOKEN='your-root-token'"
        exit 1
    fi

    # Test Vault connectivity
    if ! vault status &> /dev/null; then
        log_error "Cannot connect to Vault at ${VAULT_ADDR}"
        log_error "Ensure Vault is running and unsealed."
        exit 1
    fi

    log_info "Prerequisites check passed."
}

enable_secrets_engine() {
    log_info "Configuring secrets engine..."

    # Check if KV v2 engine already exists
    if vault secrets list -format=json | jq -e ".\"${SECRETS_PATH}/\"" &> /dev/null; then
        log_warn "Secrets engine at ${SECRETS_PATH}/ already exists. Skipping creation."
    else
        log_info "Enabling KV v2 secrets engine at ${SECRETS_PATH}/"
        vault secrets enable -path="${SECRETS_PATH}" -version=2 kv
        log_info "Secrets engine enabled successfully."
    fi
}

create_policy() {
    log_info "Creating Vault policy..."

    # Define policy with read access to agent-executor secrets
    cat > /tmp/agent-executor-policy.hcl <<EOF
# Policy for agent_executor service
# Allows read access to service secrets

path "${SECRETS_PATH}/data/*" {
  capabilities = ["read", "list"]
}

path "${SECRETS_PATH}/metadata/*" {
  capabilities = ["list"]
}
EOF

    # Write policy to Vault
    vault policy write "${POLICY_NAME}" /tmp/agent-executor-policy.hcl
    log_info "Policy '${POLICY_NAME}' created successfully."

    # Clean up temp file
    rm -f /tmp/agent-executor-policy.hcl
}

enable_approle_auth() {
    log_info "Configuring AppRole authentication..."

    # Check if AppRole is already enabled
    if vault auth list -format=json | jq -e '.["approle/"]' &> /dev/null; then
        log_warn "AppRole auth method already enabled. Skipping."
    else
        log_info "Enabling AppRole auth method..."
        vault auth enable approle
    fi

    # Create or update AppRole
    log_info "Creating AppRole '${APPROLE_NAME}'..."
    vault write "auth/approle/role/${APPROLE_NAME}" \
        token_policies="${POLICY_NAME}" \
        token_ttl=1h \
        token_max_ttl=4h \
        bind_secret_id=true

    # Get Role ID
    ROLE_ID=$(vault read -field=role_id "auth/approle/role/${APPROLE_NAME}/role-id")
    log_info "AppRole created. Role ID: ${ROLE_ID}"

    # Generate Secret ID
    SECRET_ID=$(vault write -field=secret_id -f "auth/approle/role/${APPROLE_NAME}/secret-id")
    log_info "Secret ID generated (store securely): ${SECRET_ID}"

    # Save credentials to local file for development
    cat > /tmp/vault-approle-credentials.txt <<EOF
# Vault AppRole Credentials for agent_executor
# Generated: $(date)

export VAULT_ADDR="${VAULT_ADDR}"
export VAULT_ROLE_ID="${ROLE_ID}"
export VAULT_SECRET_ID="${SECRET_ID}"

# For application configuration:
VAULT_ADDR=${VAULT_ADDR}
VAULT_ROLE_ID=${ROLE_ID}
VAULT_SECRET_ID=${SECRET_ID}
VAULT_AUTH_METHOD=approle
VAULT_SECRETS_PATH=${SECRETS_PATH}
EOF

    log_info "AppRole credentials saved to /tmp/vault-approle-credentials.txt"
    log_warn "Move this file to a secure location and add to your .env file."
}

enable_kubernetes_auth() {
    log_info "Configuring Kubernetes authentication..."

    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl not found. Skipping Kubernetes auth configuration."
        return 0
    fi

    # Check if K8s auth is already enabled
    if vault auth list -format=json | jq -e '.["kubernetes/"]' &> /dev/null; then
        log_warn "Kubernetes auth method already enabled. Updating configuration..."
    else
        log_info "Enabling Kubernetes auth method..."
        vault auth enable kubernetes
    fi

    # Get Kubernetes cluster information
    K8S_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.server}')
    K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d)

    # Configure Kubernetes auth
    log_info "Configuring Kubernetes auth method..."
    vault write auth/kubernetes/config \
        kubernetes_host="${K8S_HOST}" \
        kubernetes_ca_cert="${K8S_CA_CERT}"

    # Create Kubernetes role
    log_info "Creating Kubernetes role '${K8S_ROLE_NAME}'..."
    vault write "auth/kubernetes/role/${K8S_ROLE_NAME}" \
        bound_service_account_names="${SERVICE_ACCOUNT}" \
        bound_service_account_namespaces="${K8S_NAMESPACE}" \
        policies="${POLICY_NAME}" \
        ttl=1h

    log_info "Kubernetes auth configured successfully."
}

verify_setup() {
    log_info "Verifying Vault setup..."

    # Check secrets engine
    if vault secrets list -format=json | jq -e ".\"${SECRETS_PATH}/\"" &> /dev/null; then
        log_info "✓ Secrets engine exists at ${SECRETS_PATH}/"
    else
        log_error "✗ Secrets engine not found"
        return 1
    fi

    # Check policy
    if vault policy read "${POLICY_NAME}" &> /dev/null; then
        log_info "✓ Policy '${POLICY_NAME}' exists"
    else
        log_error "✗ Policy not found"
        return 1
    fi

    # Check AppRole
    if vault read "auth/approle/role/${APPROLE_NAME}" &> /dev/null; then
        log_info "✓ AppRole '${APPROLE_NAME}' configured"
    else
        log_warn "✗ AppRole not configured (may be intentional)"
    fi

    log_info "Vault setup verification complete."
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "Starting Vault initialization for agent_executor..."
    log_info "Vault Address: ${VAULT_ADDR}"

    check_prerequisites
    enable_secrets_engine
    create_policy
    enable_approle_auth

    # Kubernetes auth is optional
    if [[ "${ENABLE_K8S_AUTH:-false}" == "true" ]]; then
        enable_kubernetes_auth
    else
        log_info "Skipping Kubernetes auth (set ENABLE_K8S_AUTH=true to enable)"
    fi

    verify_setup

    log_info "=========================================="
    log_info "Vault initialization complete!"
    log_info "=========================================="
    log_info ""
    log_info "Next steps:"
    log_info "1. Review credentials in /tmp/vault-approle-credentials.txt"
    log_info "2. Add credentials to your .env file"
    log_info "3. Run ./populate-secrets.sh to add application secrets"
    log_info ""
}

main "$@"
