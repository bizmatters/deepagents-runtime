# Agent Executor Service - Tier 3 Scripts

This directory contains Tier 3 scripts for the `agent-executor` service, following the Script Hierarchy Model standard defined in `.claude/skills/standards/script-hierarchy-model.md`.

## Script Hierarchy Overview

| Tier | Location | Owner | Purpose |
|------|----------|-------|---------|
| **Tier 1** | `.github/workflows/` | DevOps | Pipeline definitions (GitHub Actions) |
| **Tier 2** | `platform/scripts/` | DevOps | Task orchestration (calls Tier 3 primitives) |
| **Tier 3** | `services/*/scripts/` | Backend Developer | Atomic service primitives |

This directory contains **Tier 3 scripts** owned by the Backend Developer.

---

## Directory Structure

```
services/agent_executor/scripts/
├── README.md              # Vault configuration documentation
├── TIER3_SCRIPTS.md       # This file
├── vault-init.sh          # Vault initialization (existing)
├── populate-secrets.sh    # Vault secret population (existing)
├── ci/                    # CI/Production scripts
│   ├── build.sh           # Build production Docker image
│   ├── run.sh             # Container entrypoint (production)
│   └── run-tests.sh       # Run E2E tests in CI
└── local/                 # Local development scripts
    ├── run.sh             # Start service with hot-reload
    └── run-tests.sh       # Run all tests locally
```

---

## CI Scripts (Production/CI Environment)

### `ci/build.sh`

**Purpose:** Atomic primitive for building the production Docker image.

**Usage:**
```bash
# From monorepo root
./services/agent_executor/scripts/ci/build.sh
```

**Environment Variables:**
- `PR_NUMBER` (optional): Pull request number for tagging
- `IMAGE_TAG` (optional): Override image tag
- `DOCKER_REGISTRY` (optional): Docker registry URL (default: `95.216.151.243:30500`)

**Output:**
- Builds Docker image with tag: `${DOCKER_REGISTRY}/agent-executor:${IMAGE_TAG}`
- Echoes fully-qualified image name for Tier 2 consumption

**Called by:** Tier 2 orchestration scripts (e.g., `platform/scripts/ci/run-e2e-for-pr.sh`)

**Example:**
```bash
export PR_NUMBER=123
export DOCKER_REGISTRY="registry.bizmatters.dev"
./services/agent_executor/scripts/ci/build.sh
# Output: registry.bizmatters.dev/agent-executor:pr-123-a1b2c3d
```

---

### `ci/run.sh`

**Purpose:** Container entrypoint for starting the service in production/CI.

**Usage:**
```bash
# Called by Dockerfile ENTRYPOINT (not invoked manually)
ENTRYPOINT ["/app/scripts/ci/run.sh"]
```

**Environment Variables:**
- `PORT` (required): HTTP server port (default: `8080`, Knative requirement)
- `LOG_LEVEL` (optional): Logging verbosity (default: `info`)
- `VAULT_ADDR` (required): HashiCorp Vault server address
- `VAULT_ROLE` (required): Kubernetes service account role for Vault auth

**Behavior:**
- Validates required environment variables
- Starts uvicorn without Poetry (dependencies pre-installed)
- Connects to infrastructure via environment variables
- Respects Knative `$PORT` for autoscaling

**Called by:** Docker/Kubernetes container runtime

**Notes:**
- This script runs **inside** the container
- Dependencies must be pre-installed (handled by Dockerfile)
- Never manages infrastructure (that's Tier 2/DevOps)

---

### `ci/run-tests.sh`

**Purpose:** Execute E2E tests in CI environment (inside test runner pod).

**Usage:**
```bash
# Inside test runner pod (called by Tier 2 orchestrator)
./services/agent_executor/scripts/ci/run-tests.sh
```

**Environment Variables:**
- `NATS_URL` (required): NATS server connection string
- `TEST_POSTGRES_URI` (required): PostgreSQL connection for monitoring
- `TEST_REDIS_URL` (required): Redis connection for monitoring
- `VAULT_ADDR` (required): Vault server address
- `VAULT_TOKEN` (required): Vault authentication token
- `TESTS_PATH` (optional): Path to E2E test file (default: `/root/development/bizmatters/tests/e2e/test_agent_executor_e2e.py`)

**Behavior:**
- Validates all required environment variables
- Runs pytest on E2E test suite
- Exits with pytest exit code (0 = success, 1 = failure)

**Called by:** Tier 2 orchestration scripts via `kubectl exec` or Kubernetes Job

**Example:**
```bash
kubectl exec -n langgraph test-runner -- /app/scripts/ci/run-tests.sh
```

---

### `ci/run-migrations.sh`

**Purpose:** Execute PostgreSQL database migrations for the agent-executor service.

**Usage:**
```bash
# CI environment (credentials from environment variables)
POSTGRES_PASSWORD="password" ./services/agent_executor/scripts/ci/run-migrations.sh

# Or with custom configuration
POSTGRES_HOST="custom-host" \
POSTGRES_DB="custom_db" \
POSTGRES_PASSWORD="password" \
./services/agent_executor/scripts/ci/run-migrations.sh
```

**Environment Variables:**
- `POSTGRES_HOST` - PostgreSQL host (default: postgresql.bizmatters-dev.svc.cluster.local)
- `POSTGRES_PORT` - PostgreSQL port (default: 5432)
- `POSTGRES_DB` - Database name (default: langgraph_dev)
- `POSTGRES_USER` - Database user (default: postgres)
- `POSTGRES_PASSWORD` - Database password (required)
- `MIGRATION_DIR` - Path to migration files (default: ./migrations)

**Behavior:**
- Executes all `*.up.sql` migration files in order
- Creates `agent_executor` schema
- Creates LangGraph checkpoint tables (checkpoints, checkpoint_migrations, checkpoint_blobs, checkpoint_writes)
- Exits on first failure

**Called By:**
- Tier 2 orchestration scripts (`/scripts/services/run-e2e-for-pr.sh`)
- CI/CD pipelines (`.github/workflows/`)
- Kubernetes Jobs (migration Job manifest)

**Example:**
```bash
# From Kubernetes Job
kubectl exec -n bizmatters-dev migration-job -- \
  /app/scripts/ci/run-migrations.sh
```

**Notes:**
- Requires `psql` client installed in container
- Migration files are idempotent (safe to run multiple times)
- Schema and tables use `IF NOT EXISTS` clauses

---

## Local Scripts (Development Environment)

### `local/run.sh`

**Purpose:** Start the service in local development mode with hot-reload.

**Usage:**
```bash
# From service directory
cd services/agent_executor
./scripts/local/run.sh
```

**Features:**
- Hot-reload enabled (auto-restart on code changes)
- Loads `.env` file if present
- Uses Poetry-managed virtual environment
- Default port: 8080
- Access API docs at: `http://localhost:8080/docs`

**Environment Variables:**
- `PORT` (optional): HTTP server port (default: `8080`)
- `LOG_LEVEL` (optional): Logging verbosity (default: `debug`)
- `VAULT_ADDR` (optional): Vault server address (default: `http://localhost:8200`)
- `VAULT_TOKEN` (optional): Vault authentication token (default: `root`)

**Called by:** Developer via terminal (NEVER by CI)

**Notes:**
- Requires Poetry installed
- Optional: Uncomment Docker Compose section to start local infrastructure

---

### `local/run-tests.sh`

**Purpose:** Run all tests locally (unit + integration).

**Usage:**
```bash
# From service directory
cd services/agent_executor
./scripts/local/run-tests.sh
```

**Test Stages:**
1. **Unit tests** (`tests/unit/`): Fast, isolated tests with code coverage
2. **Integration tests** (`tests/integration/`): Tests with external dependencies

**Features:**
- Color-coded output (green = pass, red = fail, yellow = warning)
- Code coverage report (HTML + terminal)
- Optional: Start/stop test containers with Docker Compose

**Environment Variables:**
- `TESTING=true`: Automatically set by script
- `LOG_LEVEL` (optional): Logging verbosity (default: `info`)
- `VAULT_ADDR` (optional): Vault server address (default: `http://localhost:8200`)
- `VAULT_TOKEN` (optional): Vault authentication token (default: `root`)

**Output:**
- Coverage report: `services/agent_executor/htmlcov/index.html`

**Called by:** Developer via terminal

**Example:**
```bash
./scripts/local/run-tests.sh
# Output:
# ================================================================================
# Stage 1: Unit Tests
# ================================================================================
# ✅ Unit tests passed
# Coverage: 87%
#
# ================================================================================
# Stage 2: Integration Tests
# ================================================================================
# ✅ Integration tests passed
#
# ✅ All tests passed successfully
```

---

## Best Practices

### For Backend Developers

1. **Always use scripts, never raw commands:**
   - ✅ `./scripts/local/run.sh`
   - ❌ `poetry run uvicorn ...`

2. **Test locally before CI:**
   - Run `./scripts/local/run-tests.sh` before pushing
   - Ensure unit and integration tests pass

3. **Keep scripts atomic:**
   - Each script does ONE thing
   - No orchestration logic in Tier 3 scripts

4. **Document environment variables:**
   - Update this document when adding new env vars
   - Use descriptive variable names

5. **Maintain backward compatibility:**
   - Scripts are called by Tier 2 orchestrators
   - Breaking changes require DevOps coordination

### For DevOps Engineers

1. **Call Tier 3 scripts from Tier 2:**
   - Never duplicate build/run logic in Tier 2
   - Use output from `build.sh` for image names

2. **Provide required environment variables:**
   - CI scripts expect infrastructure pre-provisioned
   - Pass connection strings via env vars

3. **Respect script ownership:**
   - Backend Developer owns Tier 3 scripts
   - DevOps owns Tier 2 orchestration

---

## Integration with Dockerfile

The `ci/run.sh` script is used as the container ENTRYPOINT:

```dockerfile
# Copy Tier 3 scripts
COPY scripts/ ./scripts/

# Make scripts executable
RUN chmod +x /app/scripts/ci/*.sh

# Use Tier 3 script as entrypoint
ENTRYPOINT ["/app/scripts/ci/run.sh"]
```

This ensures:
- Consistent startup behavior across environments
- Proper handling of `$PORT` for Knative autoscaling
- Centralized environment variable validation

---

## Troubleshooting

### Build script fails with "docker: command not found"
- Ensure Docker is installed and in PATH
- Build scripts must run from monorepo root

### Run script fails with "VAULT_ADDR not set"
- Check environment variables in Kubernetes deployment
- For local development, set in `.env` file

### Tests fail with "connection refused"
- Verify infrastructure is running (Vault, PostgreSQL, Redis, NATS)
- For local tests, start Docker Compose or adjust connection strings

### Hot-reload not working in local development
- Ensure you're using `./scripts/local/run.sh` (not CI script)
- Check that Poetry is installed and dependencies are up-to-date

---

## Related Documentation

- **Script Hierarchy Standard:** `.claude/skills/standards/script-hierarchy-model.md`
- **Vault Configuration:** `services/agent_executor/scripts/README.md`
- **E2E Tests:** `tests/e2e/test_agent_executor_e2e.py`
- **Service README:** `services/agent_executor/README.md`
- **Deployment Guide:** `services/agent_executor/DEPLOYMENT.md`

---

## Ownership

**Backend Developer:** Responsible for maintaining all Tier 3 scripts in this directory.

**Contact:** Ensure changes are tested locally and do not break CI/CD pipelines.
