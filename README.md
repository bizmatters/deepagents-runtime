# Agent Executor Service

A serverless, event-driven Python service responsible for the secure and stateful execution of LangGraph agents in a Knative-based environment.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Development Setup](#development-setup)
- [Configuration](#configuration)
- [Running the Service](#running-the-service)
- [Testing](#testing)
- [Event Flow](#event-flow)
- [Key Components](#key-components)
- [Observability](#observability)
- [Security](#security)
- [Deployment](#deployment)
- [References](#references)

## Overview

The Agent Executor is a Python-based, containerized service that operates as a **Kubernetes Deployment** with KEDA autoscaling. It provides:

- Event-driven LangGraph agent execution via NATS JetStream
- Stateful execution with PostgreSQL checkpointing
- Real-time streaming via Dragonfly (Redis-compatible)
- Secure credential management via External Secrets Operator (ESO)
- Zero-Touch database provisioning via Crossplane
- Automatic scaling (1-10 pods) based on NATS queue depth

### Key Capabilities

| Capability | Technology | Purpose |
|------------|-----------|---------|
| **Event Processing** | NATS JetStream + KEDA | Consume execution tasks from durable queue |
| **State Persistence** | PostgreSQL + LangGraph Checkpointer | Durable, resumable agent execution |
| **Real-time Streaming** | Dragonfly (Redis-compatible) | Live execution event streaming |
| **Secret Management** | External Secrets Operator (ESO) | LLM API keys from AWS SSM |
| **Database Provisioning** | Crossplane | Zero-Touch PostgreSQL and Dragonfly provisioning |
| **Observability** | OpenTelemetry + Prometheus | Distributed tracing and metrics |
| **Scaling** | KEDA (NATS JetStream trigger) | Automatic pod scaling based on queue depth |

## Architecture

### Deployment Architecture

- **Namespace**: `intelligence-deepagents` (intelligence layer)
- **Deployment Type**: Kubernetes Deployment with KEDA autoscaling
- **Service Account**: `default` (no Vault auth needed)
- **Scaling Policy**: 1-10 pods based on NATS JetStream queue depth
- **Resource Limits**: 500m-2000m CPU / 1-4Gi memory per pod
- **Database**: Dedicated PostgreSQL via Crossplane claim
- **Cache**: Dedicated Dragonfly via Crossplane claim

### High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    NATS JetStream (Stream)                       │
│                      AGENT_EXECUTION                             │
│                 (Durable, persistent queue)                      │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                         KEDA Scaler                              │
│          (Monitors queue depth, scales deployment)               │
└──────────────────────────────┬──────────────────────────────────┘
                               │ Scales 1-10 pods
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Agent Executor Pod                          │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  NATS Consumer                                           │  │
│  │  - Pulls messages from JetStream                        │  │
│  │  - Consumer: agent-executor-workers                     │  │
│  └────────────────┬─────────────────────────────────────────┘  │
│                   │                                              │
│  ┌────────────────▼─────────────────────────────────────────┐  │
│  │  Core Logic Layer                                        │  │
│  │  - GraphBuilder: Compile LangGraph from definition      │  │
│  │  - ExecutionManager: Run graph with checkpointing       │  │
│  └────────────────┬─────────────────────────────────────────┘  │
│                   │                                              │
│  ┌────────────────▼─────────────────────────────────────────┐  │
│  │  Services Layer                                          │  │
│  │  - DragonflyClient: Event streaming                     │  │
│  │  - NATS Publisher: Result publishing                    │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────┬─────────────────┬─────────────────┬──────────────────┘
          │                 │                 │
          ▼                 ▼                 ▼
    ┌─────────┐       ┌──────────┐      ┌──────────┐
    │   ESO   │       │PostgreSQL│      │Dragonfly │
    │(AWS SSM)│       │(Crossplane)     │(Crossplane)
    │LLM Keys │       │Checkpoints│     │ Streams  │
    └─────────┘       └──────────┘      └──────────┘
          
          ▼ Publish result
┌─────────────────────────────────────────────────────────────────┐
│                    NATS JetStream (Stream)                       │
│                      AGENT_RESULTS                               │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Required Software

- **Python**: 3.11 or higher
- **uv**: Fast Python package manager for dependency management
- **Docker**: For building container images

### Required Infrastructure

The following services must be accessible:

| Service | Address | Purpose |
|---------|---------|---------|
| **PostgreSQL** | `agent-executor-db.databases.svc:5432` | State persistence (Crossplane-provisioned) |
| **Dragonfly** | `agent-executor-cache.databases.svc:6379` | Event streaming (Crossplane-provisioned) |
| **NATS** | `nats.nats.svc:4222` | Message queue (JetStream) |
| **KEDA** | Installed in cluster | Autoscaling based on NATS queue |
| **ESO** | External Secrets Operator | Syncs LLM keys from AWS SSM |
| **Crossplane** | Installed in cluster | Database provisioning |

### Secret Configuration

**LLM API Keys (AWS SSM via ESO):**
```bash
# AWS SSM Parameters
/zerotouch/prod/agent-executor/openai_api_key
/zerotouch/prod/agent-executor/anthropic_api_key

# ESO syncs these to Kubernetes Secret: agent-executor-llm-keys
```

**Database Credentials (Crossplane-managed):**
```bash
# Automatically created by Crossplane claims
agent-executor-db-app        # PostgreSQL credentials
agent-executor-dragonfly     # Dragonfly credentials

# NO manual configuration needed
```

## Project Structure

```
agent_executor/
├── agent_executor/              # Main application package
│   ├── __init__.py
│   ├── api/                     # FastAPI application and endpoints
│   │   ├── __init__.py
│   │   └── main.py             # API entry point, dependency injection
│   ├── core/                    # Core business logic
│   │   ├── __init__.py
│   │   ├── builder.py          # GraphBuilder: Compile agent definitions
│   │   ├── executor.py         # ExecutionManager: Run graphs
│   │   ├── factory.py          # build_agent_from_definition factory
│   │   ├── model_identifier.py # LLM model configuration
│   │   ├── tool_loader.py      # Dynamic tool loading
│   │   └── subagent_builder.py # Sub-agent compilation
│   ├── services/                # External service integrations
│   │   ├── __init__.py
│   │   ├── vault.py            # VaultClient: Kubernetes Auth + secret retrieval
│   │   ├── redis.py            # RedisClient: Pub/Sub streaming
│   │   └── cloudevents.py      # CloudEventEmitter: Result publishing
│   ├── models/                  # Pydantic data models
│   │   ├── __init__.py
│   │   └── events.py           # CloudEvent structures
│   └── observability/           # Logging, tracing, metrics
│       ├── __init__.py
│       ├── logging.py          # Structured logging setup
│       └── metrics.py          # Prometheus metrics
├── tests/                       # Test suite
│   ├── unit/                   # Unit tests (isolated components)
│   │   ├── test_builder.py
│   │   ├── test_vault.py
│   │   ├── test_redis.py
│   │   └── test_cloudevents.py
│   └── integration/            # Integration tests (full flow)
│       └── test_execution_flow.py
├── pyproject.toml              # Poetry dependencies and configuration
├── Dockerfile                  # Multi-stage container build
├── README.md                   # This file
├── DEPLOYMENT.md               # Deployment guide
└── TROUBLESHOOTING.md          # Debugging guide
```

## Development Setup

### 1. Install Dependencies

```bash
cd services/agent_executor
uv sync --all-extras
```

This will:
- Create a virtual environment at `.venv/`
- Install all production dependencies
- Install development dependencies (pytest, black, ruff, mypy)
- Generate `uv.lock` lockfile for reproducible installs

### 2. Configure Environment Variables

Create a `.env` file for local development:

```bash
# Vault configuration
export VAULT_ADDR=http://localhost:8200

# Knative sink for result events (local dev)
export K_SINK=http://localhost:8081/broker

# Optional: Override PostgreSQL connection
export PG_HOST=localhost
export PG_PORT=5432
export PG_USER=postgres
export PG_PASSWORD=postgres
export PG_DATABASE=bizmatters

# Optional: Override Redis connection
export REDIS_HOST=localhost
export REDIS_PORT=6379
```

### 3. Activate Virtual Environment

```bash
source .venv/bin/activate
```

Or use `uv run` to execute commands directly without activating:

```bash
uv run <command>
```

### 4. Run Code Quality Tools

```bash
# Format code with Black
uv run black .

# Lint with Ruff
uv run ruff check .

# Type check with mypy
uv run mypy agent_executor
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `VAULT_ADDR` | Yes | - | Vault server URL |
| `K_SINK` | Yes | - | Knative sink URL for result events |
| `PG_HOST` | No | From Vault | PostgreSQL host (override) |
| `PG_PORT` | No | From Vault | PostgreSQL port (override) |
| `PG_USER` | No | From Vault | PostgreSQL username (override) |
| `PG_PASSWORD` | No | From Vault | PostgreSQL password (override) |
| `PG_DATABASE` | No | From Vault | PostgreSQL database (override) |
| `REDIS_HOST` | No | From Vault | Redis host (override) |
| `REDIS_PORT` | No | From Vault | Redis port (override) |
| `LOG_LEVEL` | No | `INFO` | Logging level (DEBUG, INFO, WARNING, ERROR) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | No | - | OpenTelemetry collector endpoint |

**Note**: Environment variable overrides are primarily for local development. In production, all credentials are retrieved from Vault.

### Vault Paths

The service expects secrets at these Vault paths:

```
secret/data/agent-executor/postgres
secret/data/agent-executor/redis
secret/data/agent-executor/llm-providers/openai
secret/data/agent-executor/llm-providers/anthropic
```

## Running the Service

### Local Development

```bash
# Start the FastAPI service with auto-reload
uv run uvicorn agent_executor.api.main:app --reload --port 8080

# Or use the project script
uv run agent-executor
```

The service will be available at:
- API endpoint: `http://localhost:8080/`
- Health check: `http://localhost:8080/health`
- Readiness check: `http://localhost:8080/ready`
- Metrics: `http://localhost:8080/metrics`

### Test CloudEvent Request

Send a test CloudEvent to the local service:

```bash
curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/cloudevents+json" \
  -d '{
    "specversion": "1.0",
    "type": "dev.my-platform.agent.execute",
    "source": "test-client",
    "id": "test-job-123",
    "datacontenttype": "application/json",
    "data": {
      "job_id": "test-job-123",
      "agent_definition": {
        "tool_definitions": [],
        "nodes": [{
          "type": "orchestrator",
          "name": "main",
          "model": {"provider": "openai", "model_name": "gpt-4o"},
          "system_prompt": "You are a helpful assistant.",
          "tools": []
        }],
        "edges": []
      },
      "input": {
        "messages": [{"role": "user", "content": "Hello!"}]
      }
    }
  }'
```

## Testing

### Run All Tests

```bash
uv run pytest
```

### Run Unit Tests Only

```bash
uv run pytest tests/unit/
```

### Run Integration Tests Only

```bash
uv run pytest tests/integration/
```

### Run Tests with Coverage

```bash
uv run pytest --cov=agent_executor --cov-report=html
```

Coverage report will be generated in `htmlcov/index.html`.

### Run Specific Test File

```bash
uv run pytest tests/unit/test_vault.py -v
```

### Test Configuration

Tests are configured in `pyproject.toml`:
- Test discovery pattern: `test_*.py`
- Async mode: Auto-detect
- Coverage threshold: Configured in CI/CD pipeline

## Event Flow

### Inbound Event Flow (Task Consumption)

```
1. Message published to NATS JetStream (stream: AGENT_EXECUTION)
   ↓
2. KEDA monitors queue depth, scales deployment if needed
   ↓
3. NATS Consumer (in agent-executor pod) pulls message
   ↓
4. Consumer: agent-executor-workers (durable, explicit ACK)
   ↓
5. Service compiles LangGraph from definition
   ↓
6. Service executes graph with PostgreSQL checkpointing
   ↓
7. Real-time events streamed to Dragonfly
   ↓
8. Message ACKed after successful execution
```

### Outbound Event Flow (Status Reporting)

```
1. Graph execution completes (success or failure)
   ↓
2. Service creates result message
   ↓
3. Service publishes to NATS JetStream (stream: AGENT_RESULTS)
   ↓
4. Downstream consumers receive result
```

### Dragonfly Streaming Events

During execution, the following events are published to `langgraph:stream:{thread_id}`:

| Event Type | Description | Data Fields |
|------------|-------------|-------------|
| `on_llm_stream` | Token generation from LLM | `token`, `cumulative_text` |
| `on_tool_start` | Tool execution begins | `tool_name`, `tool_input` |
| `on_tool_end` | Tool execution completes | `tool_name`, `tool_output` |
| `end` | Graph execution complete | `final_result` |

## Key Components

### API Layer

**File**: `agent_executor/api/main.py`

- FastAPI application with CloudEvent endpoint
- Dependency injection for services (VaultClient, RedisClient, etc.)
- Error handling and CloudEvent validation
- Health check and readiness endpoints
- Prometheus metrics endpoint

**Key Endpoints**:
- `POST /`: Accepts CloudEvent for agent execution
- `GET /health`: Liveness probe (returns 200 if running)
- `GET /ready`: Readiness probe (checks Vault, DB, Redis connectivity)
- `GET /metrics`: Prometheus-compatible metrics

### Core Logic Layer

#### GraphBuilder (`core/builder.py`)

Dynamically compiles LangGraph graphs from agent definitions:
- Loads tool definitions and creates tool instances
- Parses node and edge structures
- Compiles sub-agents with their tools and prompts
- Assembles the main orchestrator graph

**Key Method**:
```python
def build_from_definition(self, definition: Dict[str, Any]) -> Runnable:
    # Returns a compiled LangGraph graph ready for execution
```

#### ExecutionManager (`core/executor.py`)

Manages graph execution with checkpointing and streaming:
- Configures PostgreSQL checkpointer
- Executes graph with thread_id for state persistence
- Streams events to Redis during execution
- Handles errors and publishes results

**Key Method**:
```python
async def execute(self, graph: Runnable, input_data: dict, thread_id: str) -> dict:
    # Returns final execution result
```

### Services Layer

#### VaultClient (`services/vault.py`)

Handles Vault authentication and secret retrieval:
- Kubernetes Auth using ServiceAccount JWT
- Retrieves PostgreSQL credentials
- Retrieves Redis configuration
- Retrieves LLM provider API keys

**Key Methods**:
```python
def authenticate(self) -> None:
    # Authenticates using Kubernetes Auth

def get_postgres_credentials(self) -> Dict[str, Any]:
    # Returns PostgreSQL connection details

def get_llm_api_key(self, provider: str) -> Dict[str, Any]:
    # Returns API key for specified LLM provider
```

#### RedisClient (`services/redis.py`)

Manages Redis Pub/Sub for real-time event streaming:
- Publishes execution events to Redis channels
- Uses channel pattern: `langgraph:stream:{thread_id}`

**Key Method**:
```python
def publish_stream_event(self, thread_id: str, event_type: str, data: dict) -> None:
    # Publishes event to Redis channel
```

#### CloudEventEmitter (`services/cloudevents.py`)

Creates and publishes result CloudEvents:
- Constructs CloudEvents for job completion/failure
- POSTs to K_SINK URL
- Handles retry logic for failed publishes

**Key Method**:
```python
async def emit_result(self, job_id: str, status: str, result: dict) -> None:
    # Publishes result CloudEvent to broker
```

## Observability

### Structured Logging

All logs are output in JSON format with standard fields:

```json
{
  "timestamp": "2025-11-13T10:15:30.123Z",
  "level": "info",
  "message": "Graph execution completed",
  "trace_id": "uuid-trace-123",
  "job_id": "uuid-job-456",
  "component": "ExecutionManager",
  "duration_ms": 1250
}
```

**Log Levels**:
- `DEBUG`: Detailed execution flow (local dev only)
- `INFO`: Standard operational events
- `WARNING`: Recoverable issues (retries, fallbacks)
- `ERROR`: Execution failures, integration errors

### Distributed Tracing

OpenTelemetry integration provides distributed tracing:
- `trace_id` extracted from CloudEvent context
- Spans created for key operations:
  - Vault authentication
  - Database connection
  - Graph compilation
  - Graph execution
  - Redis publish operations

### Metrics

Prometheus-compatible metrics available at `/metrics`:

| Metric | Type | Description |
|--------|------|-------------|
| `agent_executor_jobs_total{status}` | Counter | Total jobs processed (completed/failed) |
| `agent_executor_job_duration_seconds` | Histogram | Job execution duration |
| `agent_executor_vault_auth_failures_total` | Counter | Vault authentication failures |
| `agent_executor_db_connection_errors_total` | Counter | Database connection errors |
| `agent_executor_redis_publish_errors_total` | Counter | Redis publish failures |

### Health Checks

**Liveness Probe** (`/health`):
- Returns 200 if service is running
- Does not check external dependencies
- Used by Kubernetes to restart unhealthy pods

**Readiness Probe** (`/ready`):
- Returns 200 only if service can connect to:
  - Vault (authenticated)
  - PostgreSQL (connection pool ready)
  - Redis (connection established)
- Used by Kubernetes to route traffic

## Security

### Credential Management

- **No secrets in code or configuration**: All credentials retrieved from Vault at runtime
- **Kubernetes Auth**: Service authenticates using ServiceAccount JWT
- **Least privilege**: Vault policy grants read-only access to required paths only
- **Credential rotation**: Vault tokens have TTL of 1 hour, automatically renewed

### Network Security

- **Network Policies**: Restrict ingress to Knative Broker, egress to required services
- **Service-to-service**: All communication within cluster (no external exposure)
- **TLS**: External LLM API calls use HTTPS
- **Future**: Consider Linkerd for mTLS between services

### Container Security

- **Non-root user**: Container runs as `appuser` (not root)
- **Minimal base image**: `python:3.11-slim` reduces attack surface
- **No shell**: Production container does not include bash or other shells
- **Read-only filesystem**: Application code mounted read-only (where possible)

## Deployment

For complete deployment procedures and infrastructure setup, see:
- **Infrastructure Documentation**: `/infrastructure/k8s/langgraph/README.md`
- **Deployment Script**: `/scripts/services/deploy-agent-executor.sh`

### Quick Deployment

Using the Tier 2 orchestration script:

```bash
# Build and deploy using orchestration script
./scripts/services/deploy-agent-executor.sh --build

# Verify deployment
kubectl get ksvc agent-executor -n langgraph
```

### KEDA Autoscaling

The service uses KEDA with NATS JetStream trigger:
- **Trigger**: NATS JetStream consumer lag
- **Lag Threshold**: 5 messages
- **Min Replicas**: 1 (always at least one pod running)
- **Max Replicas**: 10
- **Consumer**: agent-executor-workers (durable)

### Scaling Behavior

| Scenario | Scaling Action |
|----------|----------------|
| No jobs queued | Maintain 1 pod (minReplicaCount: 1) |
| 1-5 jobs in queue | 1 pod handles sequentially |
| 6-10 jobs in queue | Scale to 2 pods |
| 50+ jobs in queue | Scale to 10 pods (max) |
| Queue drains | Scale down to 1 pod |

## References

### Internal Documentation

- [Requirements Document](./.kiro/specs/agent-builder/phase1-9-agent_executor_service/requirements.md)
- [Design Document](./.kiro/specs/agent-builder/phase1-9-agent_executor_service/design.md)
- [Implementation Tasks](./.kiro/specs/agent-builder/phase1-9-agent_executor_service/tasks.md)
- [Infrastructure Documentation](/infrastructure/k8s/langgraph/README.md)
- [Operational Runbook](/infrastructure/docs/operational-runbook.md)

### Architecture Documents

- [Platform Architecture](../../docs/architecture.md)
- [Framework Standards](../../docs/frameworks.md)
- [Code Modularity Standards](../../.claude/skills/standards/code-modularity-standards.md)

### External Documentation

- [LangGraph Documentation](https://python.langchain.com/docs/langgraph)
- [Knative Serving](https://knative.dev/docs/serving/)
- [Knative Eventing](https://knative.dev/docs/eventing/)
- [CloudEvents Specification](https://cloudevents.io/)
- [HashiCorp Vault](https://www.vaultproject.io/docs)
- [FastAPI Documentation](https://fastapi.tiangolo.com/)

## Contributing

### Code Standards

- **Python Version**: 3.11+
- **Code Style**: Black (line length 100)
- **Linting**: Ruff with project configuration
- **Type Checking**: mypy (strict mode)
- **Testing**: pytest with async support

### Pull Request Process

1. Create feature branch from `main`
2. Implement changes following code standards
3. Add/update tests (maintain >80% coverage)
4. Update documentation if needed
5. Run quality checks: `black`, `ruff`, `mypy`, `pytest`
6. Create PR with descriptive title and summary
7. Address review feedback
8. Squash and merge after approval

### Testing Requirements

- All new features must include unit tests
- Integration tests for external service interactions
- Mock external dependencies in unit tests
- Use fixtures for common test setup

## License

Proprietary - Bizmatters Platform

---

**Last Updated**: 2025-11-13
**Version**: 0.1.0
**Maintained By**: Backend Engineering Team
