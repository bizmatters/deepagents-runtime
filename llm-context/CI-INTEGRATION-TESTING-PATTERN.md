# CI Testing Patterns - deepagents-runtime

## Date: 2024-12-21
## Context: In-Cluster Testing Strategy for Production-Grade CI/CD

---

## Core Testing Patterns

### 1. **Quality Gate Pattern**
- Auto-discovers all quality workflows without manual configuration
- Prevents production deployments until all quality checks pass
- Smart filtering distinguishes quality checks from deployment workflows
- Never requires updates when adding new test workflows

### 2. **Reusable In-Cluster Testing Pattern**
- Tests run in identical infrastructure to production (Kubernetes cluster)
- Uses real service dependencies (databases, message queues, caches)
- GitOps-based deployment mirrors production patterns
- Tests execute as Kubernetes Jobs within the cluster

### 3. **Environment Consistency Pattern**
- CI environment replicates production networking and security
- Auto-generated secrets and credential injection
- In-cluster DNS resolution and service communication
- Environment-specific resource optimization for CI efficiency

### 4. **Smart LLM Testing Pattern**
- Mock LLM for pull requests (cost-effective, fast feedback)
- Real LLM for main branch (production validation)
- User-configurable for manual testing scenarios
- Automatic mode selection based on trigger context

---

## CI Stability Scripts

### Mandatory Project Structure
```
scripts/
├── ci/                           # Core CI automation scripts
│   ├── build.sh                  # Docker image building (production/CI modes)
│   ├── deploy.sh                 # GitOps service deployment automation
│   ├── in-cluster-test.sh        # Main in-cluster test execution script
│   ├── test-job-template.yaml    # Kubernetes Job template for tests
│   ├── run.sh                    # Service runtime execution
│   ├── run-migrations.sh         # Database migration execution
│   ├── pre-deploy-diagnostics.sh # Infrastructure readiness validation
│   ├── post-deploy-diagnostics.sh# Service health verification
│   └── validate-platform-dependencies.sh # Platform dependency checks
├── helpers/                      # Service readiness utilities
│   ├── wait-for-postgres.sh      # PostgreSQL readiness validation
│   ├── wait-for-dragonfly.sh     # Dragonfly cache readiness validation
│   ├── wait-for-externalsecret.sh# External Secrets Operator validation
│   └── wait-for-secret.sh        # Kubernetes secret availability validation
├── patches/                      # CI environment optimizations
│   ├── 00-apply-all-patches.sh   # Master patch application script
│   ├── 01-downsize-postgres.sh   # PostgreSQL resource optimization
│   ├── 02-downsize-dragonfly.sh  # Dragonfly cache resource optimization
│   └── 03-downsize-application.sh# Application resource optimization
└── local/                        # Local development utilities
    └── ci/                       # Local CI simulation scripts
```

### Core CI Scripts (`scripts/ci/`)
- **`build.sh`**: Docker image building with production and CI modes
- **`deploy.sh`**: Service deployment automation using GitOps patterns
- **`in-cluster-test.sh`**: Main script for running test suites in Kubernetes cluster
- **`run.sh`**: Service runtime execution script
- **`run-migrations.sh`**: Database migration execution in CI environment

### Infrastructure Management Scripts
- **`pre-deploy-diagnostics.sh`**: Infrastructure readiness validation before deployment
- **`post-deploy-diagnostics.sh`**: Service health verification after deployment
- **`validate-platform-dependencies.sh`**: Platform dependency validation

### Resource Optimization Scripts (`scripts/patches/`)
- **`00-apply-all-patches.sh`**: Applies all CI environment optimizations
- **`01-downsize-postgres.sh`**: PostgreSQL resource optimization for CI
- **`02-downsize-dragonfly.sh`**: Dragonfly cache resource optimization for CI
- **`03-downsize-application.sh`**: Application resource optimization for CI

### Service Helper Scripts (`scripts/helpers/`)
- **`wait-for-postgres.sh`**: PostgreSQL readiness validation
- **`wait-for-dragonfly.sh`**: Dragonfly cache readiness validation
- **`wait-for-externalsecret.sh`**: External Secrets Operator validation
- **`wait-for-secret.sh`**: Kubernetes secret availability validation

### Test Infrastructure
- **`test-job-template.yaml`**: Kubernetes Job template for in-cluster test execution
- **`tests/integration/in_cluster_conftest.py`**: Centralized test configuration for in-cluster execution

### **MANDATORY: Template Reuse Requirement**
**ALL CI workflows MUST reuse the standard templates:**
- **`.github/workflows/in-cluster-test.yml`**: Reusable workflow template - MUST be used by all test workflows
- **`scripts/ci/test-job-template.yaml`**: Kubernetes Job template - MUST be used for all in-cluster test execution
- **No custom workflow implementations** - ensures consistency, maintainability, and reliability across all services
- **Template parameters** provide customization while maintaining standardized infrastructure patterns

---

## Testing Flow

1. **Code Change Trigger**: Path-based triggering for relevant test suites
2. **Parallel Test Execution**: Multiple test suites run simultaneously
3. **Infrastructure Provisioning**: Automated cluster and service setup
4. **In-Cluster Test Jobs**: Tests execute within Kubernetes environment
5. **Quality Gate Validation**: Auto-discovery of all workflow results
6. **Production Build**: Triggered only after all quality checks pass

---

## Key Benefits

- **High Confidence**: Tests against real infrastructure eliminate environment-specific issues
- **Cost Optimized**: Smart LLM usage reduces API costs while maintaining quality
- **Maintainable**: Auto-discovery patterns reduce maintenance overhead
- **Scalable**: Reusable patterns support adding new test suites easily
- **Observable**: Comprehensive diagnostics enable quick issue resolution

---

## Best Practices

### DO
- Use real infrastructure components for integration testing
- Implement comprehensive diagnostic scripts for failure analysis
- Auto-inject credentials from Kubernetes secrets
- Mirror production deployment patterns in CI
- Use smart resource optimization for CI environments

### DON'T
- Mock infrastructure components in integration tests
- Hardcode credentials or connection strings
- Skip comprehensive failure diagnostics
- Use different deployment patterns between CI and production
- Ignore resource constraints and cleanup procedures