"""
FastAPI Application for Agent Executor Service.

This module implements the main FastAPI application that serves as the entry point
for the Agent Executor service. It handles incoming CloudEvents from Knative,
orchestrates agent execution, and emits result CloudEvents.

The application provides:
- CloudEvent ingestion endpoint (POST /)
- Health check endpoint (GET /health)
- Dependency injection for all service components
- Structured logging and OpenTelemetry tracing
- Error handling for malformed events and execution failures

Architecture:
    Knative Broker → POST / → Parse CloudEvent → Build Graph → Execute → Emit Result

References:
    - Requirements: Req. 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 3.1, 5.1, 5.3, 5.5, NFR-3.1, NFR-4.1
    - Design: Section 2.11 (Internal Component Architecture), Section 3.1 (API Layer)
    - Tasks: Task 8 (FastAPI Application and Endpoint)
"""

import logging
import os
import time
import traceback
from contextlib import asynccontextmanager
from typing import Any, AsyncGenerator, Dict

import structlog
from pathlib import Path
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import ValidationError

# Import OpenTelemetry instrumentation
try:
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource, SERVICE_NAME
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
    OTEL_AVAILABLE = True
except ImportError:
    OTEL_AVAILABLE = False
    import warnings
    warnings.warn(
        "OpenTelemetry FastAPI instrumentation not available. "
        "Install opentelemetry-instrumentation-fastapi for tracing support.",
        ImportWarning
    )

# Import service components
from agent_executor.core.builder import GraphBuilder
from agent_executor.core.executor import ExecutionManager
from agent_executor.models.events import JobExecutionEvent
from agent_executor.services.cloudevents import CloudEventEmitter
from agent_executor.services.redis import RedisClient

# Import observability components
from agent_executor.observability.metrics import (
    agent_executor_jobs_total,
    agent_executor_job_duration_seconds,
    get_metrics
)

# Import asyncio for background tasks
import asyncio

# Configure structured logging
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=False,
)

logger = structlog.get_logger(__name__)

# Configure OpenTelemetry SDK with OTLP exporter
if OTEL_AVAILABLE:
    # Read service name from environment variable or use default
    service_name = os.getenv("OTEL_SERVICE_NAME", "agent-executor-service")

    # Create resource with service name
    resource = Resource(attributes={
        SERVICE_NAME: service_name
    })

    # Create TracerProvider with resource
    tracer_provider = TracerProvider(resource=resource)

    # Configure OTLP exporter (reads from OTEL_EXPORTER_OTLP_ENDPOINT env var)
    # Default endpoint: http://localhost:4317
    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
    otlp_exporter = OTLPSpanExporter(endpoint=otlp_endpoint)

    # Add BatchSpanProcessor for efficient span export
    span_processor = BatchSpanProcessor(otlp_exporter)
    tracer_provider.add_span_processor(span_processor)

    # Set the global tracer provider
    trace.set_tracer_provider(tracer_provider)

    # Get tracer for this module
    tracer = trace.get_tracer(__name__)

    logger.info(
        "opentelemetry_sdk_configured",
        service_name=service_name,
        otlp_endpoint=otlp_endpoint
    )
else:
    tracer = None


# Global service instances (initialized in lifespan)
_redis_client: RedisClient | None = None
_execution_manager: ExecutionManager | None = None
_cloudevent_emitter: CloudEventEmitter | None = None
_nats_consumer: Any = None
_nats_consumer_task: asyncio.Task | None = None


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """
    FastAPI lifespan context manager for startup and shutdown events.

    Startup:
    - Validates required environment variables
    - Reads credentials from environment variables (populated by Kubernetes Secrets)
    - Initializes RedisClient, ExecutionManager, CloudEventEmitter
    - Starts NATS consumer as background task
    - Sets up OpenTelemetry instrumentation

    Shutdown:
    - Stops NATS consumer
    - Closes all service connections
    - Cleans up resources

    Raises:
        RuntimeError: If required environment variables are missing
        Exception: If any service initialization fails

    References:
        - Requirements: Req. 1.1, 1.2, 2.1, 14.1, 14.2, NFR-3.1
        - Tasks: Task 1.1, 1.2, 1.3
    """
    global _redis_client, _execution_manager, _cloudevent_emitter, _nats_consumer, _nats_consumer_task

    # Load .env file if it exists (for local development/testing)
    # Use explicit path to ensure .env is found regardless of working directory
    env_path = Path(__file__).parent.parent / ".env"
    load_dotenv(dotenv_path=env_path)

    logger.info("agent_executor_service_starting")

    try:
        # Validate required environment variables
        required_env_vars = ["POSTGRES_HOST", "POSTGRES_PASSWORD", "DRAGONFLY_HOST"]
        missing_vars = [var for var in required_env_vars if not os.getenv(var)]

        if missing_vars:
            error_msg = f"Missing required environment variables: {', '.join(missing_vars)}"
            logger.error(
                "startup_validation_failed",
                missing_variables=missing_vars,
                message=error_msg
            )
            raise RuntimeError(error_msg)

        # Build PostgreSQL credentials from environment variables
        # These are populated by Kubernetes Secrets managed by External Secrets Operator
        postgres_creds = {
            "host": os.getenv("POSTGRES_HOST"),
            "port": int(os.getenv("POSTGRES_PORT", "5432")),
            "database": os.getenv("POSTGRES_DB", "langgraph_dev"),
            "username": os.getenv("POSTGRES_USER", "postgres"),
            "password": os.getenv("POSTGRES_PASSWORD")
        }

        # Build Dragonfly (Redis-compatible) configuration from environment variables
        dragonfly_config = {
            "host": os.getenv("DRAGONFLY_HOST"),
            "port": int(os.getenv("DRAGONFLY_PORT", "6379")),
            "password": os.getenv("DRAGONFLY_PASSWORD")  # May be None if no auth
        }

        logger.info(
            "credentials_loaded_from_environment",
            postgres_host=postgres_creds['host'],
            postgres_port=postgres_creds['port'],
            postgres_database=postgres_creds['database'],
            dragonfly_host=dragonfly_config['host'],
            dragonfly_port=dragonfly_config['port'],
            nats_url=os.getenv("NATS_URL", "nats://nats.nats.svc:4222")
        )

        # Build PostgreSQL connection string with search_path
        # Support preview environment schema override via POSTGRES_SCHEMA env var
        schema_name = os.getenv("POSTGRES_SCHEMA", "agent_executor")

        # psycopg v3 requires search_path via options parameter with URL encoding
        postgres_connection_string = (
            f"postgresql://{postgres_creds['username']}:{postgres_creds['password']}"
            f"@{postgres_creds['host']}:{postgres_creds['port']}/{postgres_creds['database']}"
            f"?sslmode=prefer&options=-c%20search_path%3D{schema_name}"
        )
        logger.info(
            "postgres_connection_string_built",
            host=postgres_creds['host'],
            port=postgres_creds['port'],
            database=postgres_creds['database'],
            schema=schema_name
        )

        # Initialize RedisClient (connects to Dragonfly)
        logger.info("initializing_redis_client")
        redis_kwargs = {
            "host": dragonfly_config['host'],
            "port": dragonfly_config['port']
        }
        if dragonfly_config.get('password'):
            redis_kwargs['password'] = dragonfly_config['password']
        
        _redis_client = RedisClient(**redis_kwargs)
        logger.info("redis_client_initialized")

        # Initialize ExecutionManager
        logger.info("initializing_execution_manager")
        _execution_manager = ExecutionManager(
            redis_client=_redis_client,
            postgres_connection_string=postgres_connection_string
        )
        logger.info("execution_manager_initialized")

        # Initialize CloudEventEmitter
        logger.info("initializing_cloudevent_emitter")
        _cloudevent_emitter = CloudEventEmitter()
        logger.info("cloudevent_emitter_initialized")

        # Validate LLM API keys are available as environment variables
        # LangChain/LangGraph expects API keys to be available as env vars
        # These are populated by Kubernetes Secrets managed by External Secrets Operator
        logger.info("validating_llm_api_keys")
        if os.getenv("OPENAI_API_KEY"):
            logger.info("openai_api_key_available")
        else:
            logger.warning("openai_api_key_not_set")

        if os.getenv("ANTHROPIC_API_KEY"):
            logger.info("anthropic_api_key_available")
        else:
            logger.warning("anthropic_api_key_not_set")

        # Initialize NATS consumer
        logger.info("initializing_nats_consumer")
        from agent_executor.services.nats_consumer import NATSConsumer
        
        _nats_consumer = NATSConsumer(
            nats_url=os.getenv("NATS_URL", "nats://nats.nats.svc:4222"),
            stream_name="AGENT_EXECUTION",
            consumer_group="agent-executor-workers",
            execution_manager=_execution_manager,
            cloudevent_emitter=_cloudevent_emitter
        )
        
        # Start NATS consumer as background task
        logger.info("starting_nats_consumer_background_task")
        _nats_consumer_task = asyncio.create_task(_nats_consumer.start())
        logger.info("nats_consumer_started")

        logger.info(
            "agent_executor_service_started",
            message="All services initialized successfully"
        )

        # Yield control to the application
        yield

    except Exception as e:
        logger.error(
            "startup_failed",
            error=str(e),
            error_type=type(e).__name__,
            stack_trace=traceback.format_exc()
        )
        raise

    finally:
        # Shutdown: Clean up resources
        logger.info("agent_executor_service_shutting_down")

        # Stop NATS consumer
        if _nats_consumer:
            logger.info("stopping_nats_consumer")
            await _nats_consumer.stop()
            logger.info("nats_consumer_stopped")
        
        if _nats_consumer_task and not _nats_consumer_task.done():
            logger.info("cancelling_nats_consumer_task")
            _nats_consumer_task.cancel()
            try:
                await _nats_consumer_task
            except asyncio.CancelledError:
                logger.info("nats_consumer_task_cancelled")

        if _execution_manager:
            _execution_manager.close()
            logger.info("execution_manager_closed")

        if _redis_client:
            _redis_client.close()
            logger.info("redis_client_closed")

        logger.info("agent_executor_service_stopped")


# Initialize FastAPI application
app = FastAPI(
    title="Agent Executor Service",
    description="Serverless LangGraph Agent Execution Service for Knative",
    version="0.1.0",
    lifespan=lifespan
)

# Set up OpenTelemetry instrumentation
if OTEL_AVAILABLE:
    FastAPIInstrumentor.instrument_app(app)
    logger.info("opentelemetry_instrumentation_enabled")


# Dependency injection functions

def get_redis_client() -> RedisClient:
    """
    Dependency injection for RedisClient.

    Returns:
        Initialized RedisClient instance

    Raises:
        HTTPException: If RedisClient is not initialized

    References:
        - Requirements: Req. 2.3
        - Tasks: Task 8.2
    """
    if _redis_client is None:
        logger.error("redis_client_not_initialized")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="RedisClient not initialized"
        )
    return _redis_client


def get_execution_manager() -> ExecutionManager:
    """
    Dependency injection for ExecutionManager.

    Returns:
        Initialized ExecutionManager instance

    Raises:
        HTTPException: If ExecutionManager is not initialized

    References:
        - Requirements: Req. 3.2, 4.1
        - Tasks: Task 8.2
    """
    if _execution_manager is None:
        logger.error("execution_manager_not_initialized")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="ExecutionManager not initialized"
        )
    return _execution_manager


def get_graph_builder(
    execution_manager: ExecutionManager = Depends(get_execution_manager)
) -> GraphBuilder:
    """
    Dependency injection for GraphBuilder.

    Args:
        execution_manager: ExecutionManager dependency (for accessing checkpointer)

    Returns:
        New GraphBuilder instance with checkpointer dependency

    References:
        - Requirements: Req. 3.1, 14.2
        - Tasks: Task 1.1
    """
    # Pass the checkpointer from ExecutionManager to GraphBuilder
    # This allows the graph to be compiled with checkpoint persistence
    checkpointer = execution_manager.checkpointer if execution_manager else None
    return GraphBuilder(checkpointer=checkpointer)


def get_cloudevent_emitter() -> CloudEventEmitter:
    """
    Dependency injection for CloudEventEmitter.

    Returns:
        Initialized CloudEventEmitter instance

    Raises:
        HTTPException: If CloudEventEmitter is not initialized

    References:
        - Requirements: Req. 5.1, 5.3
        - Tasks: Task 8.2
    """
    if _cloudevent_emitter is None:
        logger.error("cloudevent_emitter_not_initialized")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="CloudEventEmitter not initialized"
        )
    return _cloudevent_emitter


def get_nats_consumer():
    """
    Dependency injection for NATSConsumer.

    Returns:
        Initialized NATSConsumer instance

    Raises:
        HTTPException: If NATSConsumer is not initialized

    References:
        - Requirements: Req. 8.1
        - Tasks: Task 1.3
    """
    if _nats_consumer is None:
        logger.error("nats_consumer_not_initialized")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="NATSConsumer not initialized"
        )
    return _nats_consumer


# Health check endpoint

@app.get("/health", status_code=status.HTTP_200_OK)
async def health_check() -> Dict[str, Any]:
    """
    Health check endpoint for Kubernetes liveness probes.

    Simple liveness check that returns 200 OK if the service is running.
    Does not check external dependencies.

    Returns:
        200 OK: Service is alive

    Response format:
        {
            "status": "healthy"
        }

    References:
        - Requirements: 17.1
        - Design: Section 2.8 (Observability Design)
        - Tasks: Task 1.6
    """
    return {"status": "healthy"}


@app.get("/ready", status_code=status.HTTP_200_OK)
async def readiness_check(
    redis_client: RedisClient = Depends(get_redis_client),
    execution_manager: ExecutionManager = Depends(get_execution_manager),
    nats_consumer = Depends(get_nats_consumer)
) -> Dict[str, Any]:
    """
    Readiness check endpoint for Kubernetes readiness probes.

    Checks connectivity to all external dependencies:
    - Dragonfly (Redis-compatible cache)
    - PostgreSQL (via ExecutionManager)
    - NATS (via NATSConsumer)

    Returns:
        200 OK: All services are ready
        503 Service Unavailable: One or more services are unreachable

    Response format:
        {
            "status": "ready" | "not_ready",
            "services": {
                "dragonfly": true | false,
                "postgres": true | false,
                "nats": true | false
            }
        }

    References:
        - Requirements: 17.2, 17.3
        - Design: Section 2.8 (Observability Design)
        - Tasks: Task 1.6
    """
    services_health = {
        "dragonfly": False,
        "postgres": False,
        "nats": False
    }

    # Check Dragonfly
    try:
        services_health["dragonfly"] = redis_client.health_check()
    except Exception as e:
        logger.error("dragonfly_health_check_failed", error=str(e))
        services_health["dragonfly"] = False

    # Check PostgreSQL (via ExecutionManager)
    try:
        services_health["postgres"] = execution_manager.health_check()
    except Exception as e:
        logger.error("postgres_health_check_failed", error=str(e))
        services_health["postgres"] = False

    # Check NATS
    try:
        services_health["nats"] = nats_consumer.health_check()
    except Exception as e:
        logger.error("nats_health_check_failed", error=str(e))
        services_health["nats"] = False

    # Determine overall readiness status
    all_ready = all(services_health.values())

    if all_ready:
        logger.info("readiness_check_passed", services=services_health)
        return {
            "status": "ready",
            "services": services_health
        }
    else:
        logger.warning("readiness_check_failed", services=services_health)
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={
                "status": "not_ready",
                "services": services_health
            }
        )


# Prometheus metrics endpoint

@app.get("/metrics")
async def metrics() -> Response:
    """
    Prometheus metrics endpoint.

    Exposes metrics in Prometheus text format for scraping by Prometheus server.
    Metrics include job execution counts, durations, and infrastructure health indicators.

    Returns:
        Response with metrics in Prometheus text format

    Metrics Exposed:
        - agent_executor_jobs_total{status="completed|failed"}: Total job count
        - agent_executor_job_duration_seconds: Histogram of job durations
        - agent_executor_db_connection_errors_total: Database error count
        - agent_executor_redis_publish_total{event_type="..."}: Redis publish count
        - agent_executor_redis_publish_errors_total: Redis error count
        - agent_executor_nats_messages_processed_total: NATS messages processed
        - agent_executor_nats_messages_failed_total: NATS messages failed

    References:
        - Tasks: Task 1.6, 9.3 (Prometheus metrics endpoint)
        - Requirements: 17.4, 17.5, Observable pillar
        - Design: Section 2.8 (Observability Design)
    """
    metrics_data, content_type = get_metrics()
    return Response(content=metrics_data, media_type=content_type)


# Main CloudEvent processing endpoint

@app.post("/", status_code=status.HTTP_200_OK)
async def process_cloudevent(
    request: Request,
    graph_builder: GraphBuilder = Depends(get_graph_builder),
    execution_manager: ExecutionManager = Depends(get_execution_manager),
    cloudevent_emitter: CloudEventEmitter = Depends(get_cloudevent_emitter)
) -> Response:
    """
    Main endpoint for processing CloudEvents from Knative Broker.

    This endpoint:
    1. Receives CloudEvent from Knative (HTTP POST with CloudEvent headers)
    2. Parses JobExecutionEvent from CloudEvent data field
    3. Builds LangGraph agent from agent_definition
    4. Executes agent with streaming to Redis
    5. Emits result CloudEvent (completed or failed) to K_SINK
    6. Returns HTTP 200 OK to acknowledge processing

    Request:
        CloudEvent with type: dev.my-platform.agent.execute
        Data payload: JobExecutionEvent (trace_id, job_id, agent_definition, input_payload)

    Response:
        200 OK: Job processed and result CloudEvent emitted
        400 Bad Request: Malformed CloudEvent or JobExecutionEvent
        503 Service Unavailable: Service dependencies not available

    Error Handling:
        - Malformed events: Return 400 (no retry)
        - Execution failures: Emit job.failed CloudEvent, return 200
        - Infrastructure failures: Return 503 (Knative will retry)

    References:
        - Requirements: Req. 1.1, 1.2, 1.3, 1.4, 3.1, 5.1, 5.3, 5.5
        - Design: Section 3.1 (API Layer), Section 5 (Error Handling)
        - Tasks: Task 8.4, 8.5, 8.6
    """
    try:
        # Extract trace context from CloudEvent headers for distributed tracing
        # W3C Trace Context propagation via traceparent/tracestate headers
        if tracer and OTEL_AVAILABLE:
            carrier = dict(request.headers)
            ctx = TraceContextTextMapPropagator().extract(carrier=carrier)
        else:
            ctx = None

        # Parse CloudEvent from request
        # CloudEvent headers: ce-type, ce-source, ce-id, ce-specversion
        # CloudEvent data: JSON body
        request_body = await request.json()

        logger.info(
            "cloudevent_received",
            ce_type=request.headers.get("ce-type"),
            ce_source=request.headers.get("ce-source"),
            ce_id=request.headers.get("ce-id")
        )

        # Extract JobExecutionEvent from CloudEvent data field
        # CloudEvent structure: {"data": {...}, "specversion": "1.0", ...}
        if "data" in request_body:
            event_data = request_body["data"]
        else:
            # If no 'data' field, assume the body itself is the event data
            event_data = request_body

        # Validate and parse JobExecutionEvent using Pydantic
        try:
            job_event = JobExecutionEvent(**event_data)
        except ValidationError as e:
            logger.error(
                "malformed_job_execution_event",
                validation_errors=e.errors(),
                event_data=event_data
            )
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Malformed JobExecutionEvent: {e.errors()}"
            )

        # Extract fields from JobExecutionEvent
        trace_id = job_event.trace_id
        job_id = job_event.job_id
        agent_definition = job_event.agent_definition
        input_payload = job_event.input_payload

        # Add trace_id and job_id to logging context
        structlog.contextvars.bind_contextvars(
            trace_id=trace_id,
            job_id=job_id
        )

        logger.info(
            "processing_job_execution_event",
            trace_id=trace_id,
            job_id=job_id,
            has_agent_definition=bool(agent_definition),
            has_input_payload=bool(input_payload)
        )

        # Track job execution start time for metrics
        job_start_time = time.time()

        # Orchestration logic: Build → Execute → Emit Result
        try:
            # Step 1: Build LangGraph agent from definition
            if tracer:
                with tracer.start_as_current_span("build_agent_graph", context=ctx) as span:
                    span.set_attribute("job_id", job_id)
                    span.set_attribute("trace_id", trace_id)
                    span.set_attribute("agent.definition.id", agent_definition.get("id", "unknown"))
                    logger.info("building_agent_from_definition", job_id=job_id, trace_id=trace_id)
                    compiled_graph = graph_builder.build_from_definition(agent_definition)
                    logger.info("agent_built_successfully", job_id=job_id, trace_id=trace_id)
            else:
                logger.info("building_agent_from_definition", job_id=job_id, trace_id=trace_id)
                compiled_graph = graph_builder.build_from_definition(agent_definition)
                logger.info("agent_built_successfully", job_id=job_id, trace_id=trace_id)

            # Step 2: Execute agent with streaming
            if tracer:
                with tracer.start_as_current_span("execute_agent", context=ctx) as span:
                    span.set_attribute("job_id", job_id)
                    span.set_attribute("trace_id", trace_id)
                    span.set_attribute("thread_id", job_id)
                    logger.info("executing_agent", job_id=job_id, trace_id=trace_id)
                    result = execution_manager.execute(
                        graph=compiled_graph,
                        job_id=job_id,
                        input_payload=input_payload,
                        trace_id=trace_id
                    )
                    logger.info(
                        "agent_execution_completed",
                        job_id=job_id,
                        trace_id=trace_id,
                        has_result=bool(result)
                    )
            else:
                logger.info("executing_agent", job_id=job_id, trace_id=trace_id)
                result = execution_manager.execute(
                    graph=compiled_graph,
                    job_id=job_id,
                    input_payload=input_payload,
                    trace_id=trace_id
                )
                logger.info(
                    "agent_execution_completed",
                    job_id=job_id,
                    trace_id=trace_id,
                    has_result=bool(result)
                )

            # Step 3: Emit job.completed CloudEvent
            logger.info("emitting_completed_event", job_id=job_id, trace_id=trace_id)
            await cloudevent_emitter.emit_completed(
                job_id=job_id,
                result=result,
                trace_id=trace_id
            )
            logger.info("completed_event_emitted", job_id=job_id, trace_id=trace_id)

            # Record metrics for successful job completion
            job_duration = time.time() - job_start_time
            agent_executor_jobs_total.labels(status='completed').inc()
            agent_executor_job_duration_seconds.observe(job_duration)

            logger.info(
                "job_metrics_recorded",
                job_id=job_id,
                trace_id=trace_id,
                status="completed",
                duration_seconds=job_duration
            )

            # Return HTTP 200 OK to acknowledge successful processing
            return Response(status_code=status.HTTP_200_OK)

        except Exception as e:
            # Execution failure: Emit job.failed CloudEvent
            logger.error(
                "agent_execution_failed",
                job_id=job_id,
                trace_id=trace_id,
                error=str(e),
                error_type=type(e).__name__,
                stack_trace=traceback.format_exc()
            )

            # Construct structured error payload
            error_payload = {
                "message": str(e),
                "type": type(e).__name__,
                "stack_trace": traceback.format_exc()
            }

            # Emit job.failed CloudEvent
            logger.info("emitting_failed_event", job_id=job_id, trace_id=trace_id)
            await cloudevent_emitter.emit_failed(
                job_id=job_id,
                error=error_payload,
                trace_id=trace_id
            )
            logger.info("failed_event_emitted", job_id=job_id, trace_id=trace_id)

            # Record metrics for failed job
            job_duration = time.time() - job_start_time
            agent_executor_jobs_total.labels(status='failed').inc()
            agent_executor_job_duration_seconds.observe(job_duration)

            logger.info(
                "job_metrics_recorded",
                job_id=job_id,
                trace_id=trace_id,
                status="failed",
                duration_seconds=job_duration
            )

            # Return HTTP 200 OK (failure was handled by emitting failed event)
            # This prevents Knative from retrying the job
            return Response(status_code=status.HTTP_200_OK)

    except HTTPException:
        # Re-raise HTTPException (400 Bad Request for malformed events)
        raise

    except Exception as e:
        # Unexpected error: Log and return 503 for Knative retry
        logger.error(
            "unexpected_error_processing_cloudevent",
            error=str(e),
            error_type=type(e).__name__,
            stack_trace=traceback.format_exc()
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Unexpected error: {str(e)}"
        )

    finally:
        # Clear logging context
        structlog.contextvars.clear_contextvars()


# Application entry point for uvicorn

def main() -> None:
    """
    Entry point for running the application with uvicorn.

    Usage:
        python -m agent_executor.api.main
        or
        uvicorn agent_executor.api.main:app --host 0.0.0.0 --port 8080
    """
    import uvicorn
    uvicorn.run(
        "agent_executor.api.main:app",
        host="0.0.0.0",
        port=8080,
        log_level="info"
    )


if __name__ == "__main__":
    main()
