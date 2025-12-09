# Agent Executor Integration Tests

This directory contains **Tier 1 Critical Integration Tests** for the Agent Executor service. These tests validate the complete end-to-end data flow through PostgreSQL, Redis, and CloudEvent emission using **real infrastructure** (not mocks).

## Overview

The integration tests in this directory follow a **hybrid approach** that maximizes real-world validation while maintaining test isolation:

- **REAL Infrastructure:** PostgreSQL, Redis, LangGraph graph execution
- **MOCKED External APIs:** Vault HTTP, K_SINK HTTP, LLM Provider HTTP

This approach ensures we validate actual data flow through our core infrastructure components while avoiding external API costs and flakiness.

## Test Architecture

### What's Real vs. Mocked

#### ✅ REAL (Validates Actual Data Flow)

- **PostgreSQL Database:** Real connection via Docker Compose on `localhost:15433`
- **Redis Pub/Sub:** Real streaming events via Docker Compose on `localhost:16380`
- **LangGraph Execution:** Real graph compilation and execution
- **GraphBuilder:** Builds real graph from `tests/mock/definition.json`
- **ExecutionManager:** Executes graph with real checkpointing and streaming
- **RedisClient:** Publishes events to real Redis channels

#### ❌ MOCKED (External Dependencies Only)

- **Vault HTTP API:** Mocked via `patch("hvac.Client")`
- **K_SINK HTTP POST:** Mocked via `patch("httpx.AsyncClient")`
- **LLM Provider API:** Mocked via `patch("langchain_openai.ChatOpenAI._generate")`

### Test Files

```
tests/integration/
├── README.md                      # This file - setup and usage guide
├── VALIDATION_CRITERIA.md         # Comprehensive validation criteria documentation
├── docker-compose.test.yml        # Test infrastructure (PostgreSQL + Redis)
├── test_api.py                    # Tier 1 critical integration tests
└── __init__.py
```

## Prerequisites

### System Requirements

- **Docker:** Docker Engine 20.10+ with Docker Compose
- **Python:** Python 3.11+
- **Network Ports:** Available ports 15433 (PostgreSQL) and 16380 (Redis)

### Python Dependencies

All dependencies are included in the service's `requirements.txt`:

```bash
# Core dependencies
fastapi
uvicorn
langchain-core
langchain-openai
langgraph
psycopg[binary]
redis
httpx

# Testing dependencies
pytest
pytest-asyncio
```

## Quick Start

### 1. Start Test Infrastructure

```bash
# Navigate to service directory
cd /root/development/bizmatters/services/agent_executor

# Start PostgreSQL and Redis via Docker Compose
docker-compose -f tests/integration/docker-compose.test.yml up -d

# Verify services are healthy (wait ~10 seconds)
docker ps | grep agent-executor-test

# Expected output:
# agent-executor-test-postgres   postgres:15   Up 10 seconds (healthy)   0.0.0.0:15433->5432/tcp
# agent-executor-test-redis      redis:7-alpine   Up 10 seconds (healthy)   0.0.0.0:16380->6379/tcp
```

### 2. Run Integration Tests

```bash
# Run all integration tests
pytest tests/integration/test_api.py -v -s

# Run specific test
pytest tests/integration/test_api.py::test_cloudevent_processing_end_to_end_success -v -s

# Run with detailed traceback
pytest tests/integration/test_api.py -v -s --tb=short
```

### 3. Cleanup

```bash
# Stop and remove containers (preserves volumes)
docker-compose -f tests/integration/docker-compose.test.yml down

# Full cleanup (removes volumes and data)
docker-compose -f tests/integration/docker-compose.test.yml down -v
```

## Test Coverage

### Tier 1 Critical Tests

#### 1. `test_cloudevent_processing_end_to_end_success`

**Objective:** Validate complete happy-path data flow from CloudEvent receipt to job completion.

**Flow:**
1. Receive CloudEvent via POST `/`
2. Parse `JobExecutionEvent` from CloudEvent data
3. Build LangGraph agent from `tests/mock/definition.json` (REAL GraphBuilder)
4. Execute agent with REAL graph execution (mock only LLM HTTP API)
5. Publish stream events to REAL Redis
6. Save checkpoints to REAL PostgreSQL
7. Emit `job.completed` CloudEvent to K_SINK
8. Return HTTP 200 OK

**Validation:**
- ✅ HTTP 200 OK response
- ✅ PostgreSQL: At least 1 checkpoint with `thread_id = job_id`
- ✅ Redis: Minimum 3 events with correct structure
- ✅ CloudEvent: Emitted to K_SINK with W3C trace context

**Success Criteria:** See [VALIDATION_CRITERIA.md](./VALIDATION_CRITERIA.md#1-postgresql-checkpoint-validation)

#### 2. `test_cloudevent_processing_end_to_end_failure`

**Objective:** Validate error handling and failure CloudEvent emission.

**Flow:**
1. Receive CloudEvent via POST `/`
2. Attempt to build agent (GraphBuilder fails with exception)
3. Catch execution failure in API endpoint
4. Emit `job.failed` CloudEvent with error details
5. Return HTTP 200 OK (failure handled gracefully)

**Validation:**
- ✅ HTTP 200 OK response (prevents Knative retry)
- ✅ CloudEvent: `job.failed` emitted with stack trace
- ✅ Error details include type, message, and stack trace

**Success Criteria:** See [VALIDATION_CRITERIA.md](./VALIDATION_CRITERIA.md#3-cloudevent-emission-validation)

### Helper Tests

#### 3. `test_fixtures_are_properly_configured`

**Objective:** Verify that all test fixtures (real and mocked) are correctly initialized.

**Validation:**
- ✅ PostgreSQL connection works
- ✅ Redis connection works
- ✅ Mock fixtures are configured
- ✅ Sample data structure is valid

## Validation Criteria

For detailed validation criteria including pass/fail conditions, query examples, and data structure requirements, see:

📄 **[VALIDATION_CRITERIA.md](./VALIDATION_CRITERIA.md)**

This document covers:
- PostgreSQL checkpoint validation (thread_id, state data, schema)
- Redis streaming event validation (event types, structure, channel format)
- CloudEvent emission validation (W3C trace context, payload structure)
- Executor.py refactoring validation (no redundant compilation)

## Test Infrastructure Details

### PostgreSQL Container

- **Image:** `postgres:15`
- **Port:** `15433` (mapped from container's 5432)
- **Database:** `test_db`
- **User:** `test_user`
- **Password:** `test_pass`
- **Schema:** `agent_executor`
- **Table:** `agent_executor.checkpoints` (LangGraph PostgresSaver schema)

### Redis Container

- **Image:** `redis:7-alpine`
- **Port:** `16380` (mapped from container's 6379)
- **Channels:** `langgraph:stream:{job_id}`
- **Data:** In-memory only (no persistence)

### Healthchecks

Both services have health checks configured:

```yaml
# PostgreSQL
test: ["CMD-SHELL", "pg_isready -U test_user"]
interval: 5s
timeout: 5s
retries: 5

# Redis
test: ["CMD", "redis-cli", "ping"]
interval: 5s
timeout: 5s
retries: 5
```

## Troubleshooting

### Port Conflicts

If ports 15433 or 16380 are already in use:

```bash
# Check what's using the ports
lsof -i :15433
lsof -i :16380

# Kill conflicting processes or modify docker-compose.test.yml
```

### Connection Refused Errors

If tests fail with "Connection refused":

```bash
# Verify containers are running and healthy
docker ps | grep agent-executor-test

# Check container logs
docker logs agent-executor-test-postgres
docker logs agent-executor-test-redis

# Restart containers
docker-compose -f tests/integration/docker-compose.test.yml restart
```

### Checkpoint Table Not Found

If you see "relation does not exist" errors:

```bash
# The test fixture creates the table automatically, but you can manually verify:
docker exec -it agent-executor-test-postgres psql -U test_user -d test_db

# In psql:
\dt agent_executor.*

# Should show:
# agent_executor | checkpoints | table | test_user
```

### Import Errors

If tests fail with import errors:

```bash
# Ensure you're in the service directory
cd /root/development/bizmatters/services/agent_executor

# Install dependencies
pip install -r requirements.txt

# Run tests with PYTHONPATH set
PYTHONPATH=/root/development/bizmatters/services/agent_executor pytest tests/integration/test_api.py -v
```

### Vault Mock Not Working

If tests fail with Vault authentication errors:

```bash
# Verify the mock patches are applied correctly
# Check test output for "Mock Vault" messages

# The fixture mocks hvac.Client - ensure no real Vault connection is attempted
# Environment variables should be set by monkeypatch in test fixtures
```

## Development Workflow

### Adding New Validation Checks

1. **Update VALIDATION_CRITERIA.md** with new validation requirements
2. **Add assertions** to `test_api.py` in the relevant test function
3. **Run tests** to verify new validation works
4. **Update documentation** with examples and success criteria

### Testing Against Real LLM APIs

To test with real OpenAI/Anthropic APIs (not recommended for CI):

```python
# In test_api.py, comment out the mock_llm_api fixture:
# @pytest.mark.asyncio
# async def test_cloudevent_processing_end_to_end_success(
#     mock_vault_http: MagicMock,
#     postgres_connection: psycopg.Connection,
#     redis_client: redis.Redis,
#     # mock_llm_api: MagicMock,  # ❌ COMMENT OUT
#     mock_k_sink_http: AsyncMock,
#     sample_cloudevent: Dict[str, Any],
#     monkeypatch: pytest.MonkeyPatch
# ) -> None:

# Then set real API keys in mock_llm_key.return_value
```

**⚠️ Warning:** This will make real API calls and incur costs. Use only for debugging.

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Integration Tests

on: [push, pull_request]

jobs:
  integration-tests:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: |
          cd services/agent_executor
          pip install -r requirements.txt

      - name: Start test infrastructure
        run: |
          cd services/agent_executor
          docker-compose -f tests/integration/docker-compose.test.yml up -d
          sleep 10  # Wait for healthchecks

      - name: Run integration tests
        run: |
          cd services/agent_executor
          pytest tests/integration/test_api.py -v

      - name: Cleanup
        if: always()
        run: |
          cd services/agent_executor
          docker-compose -f tests/integration/docker-compose.test.yml down -v
```

## References

### Project Documentation

- **Specification:** `.kiro/specs/agent-builder/phase1-9-agent_executor_service/`
- **Architecture:** `architecture.md`
- **Frameworks:** `frameworks.md`

### Requirements

- **Req. 1.1:** CloudEvent ingestion via HTTP POST
- **Req. 1.2:** CloudEvent data parsing (JobExecutionEvent)
- **Req. 3.1:** PostgreSQL checkpointing with thread_id = job_id
- **Req. 3.2:** Redis streaming events
- **Req. 5.1:** CloudEvent emission to K_SINK
- **Req. 5.3:** W3C trace context propagation

### Design Sections

- **Section 2.11:** Internal Component Architecture
- **Section 3.1:** API Layer (FastAPI endpoint)
- **Section 5:** Error Handling and CloudEvent emission

### Tasks

- **Task 8.7:** Tier 1 Critical Integration Tests (Enhanced)

## Status

✅ **All validation criteria implemented and documented**

- Docker Compose test infrastructure configured
- Tier 1 critical tests implemented with real data flow
- VALIDATION_CRITERIA.md comprehensive documentation complete
- README.md setup instructions complete

**Last Updated:** 2025-11-19
**Test Version:** 1.0
**Status:** Production Ready
