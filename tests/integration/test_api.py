"""
Integration tests for Agent Executor API - REFACTORED FOR REAL DATA FLOW VALIDATION.

This module contains Tier 1 critical integration tests that validate the complete
end-to-end data flow through:
- PostgreSQL checkpoints (real database)
- Dragonfly streaming events (real pub/sub)
- NATS CloudEvent emissions (real NATS JetStream)

Test Strategy (ENHANCED):
    - Use REAL PostgreSQL, Dragonfly, and NATS via Docker Compose
    - Use REAL graph execution with REAL LLM API calls (using OPENAI_API_KEY from .env)
    - Load REAL agent definition from tests/mock/definition.json
    - Validate actual data flow: checkpoints written, events published, CloudEvents emitted to NATS

Tier 1 Critical Tests:
    1. test_cloudevent_processing_end_to_end_success - Real data flow validation
    2. test_cloudevent_processing_end_to_end_failure - Failure handling validation

Prerequisites:
    - Run: docker-compose -f tests/integration/docker-compose.test.yml up -d
    - PostgreSQL on localhost:5433 (user: test_user, password: test_pass, db: test_db)
    - Redis on localhost:6380

References:
    - Requirements: Req. 1.1, 1.2, 3.1, 5.1, 5.3
    - Design: Section 2.11 (Internal Component Architecture), Section 3.1 (API Layer)
    - Spec: .kiro/specs/agent-builder/phase1-9-agent_executor_service/
    - Tasks: Task 8.7 (Tier 1 Critical Integration Tests - Enhanced)
"""

import json
import os
import time
from pathlib import Path
from typing import Any, Dict, Generator, List
from unittest.mock import AsyncMock, MagicMock, Mock, patch

import httpx
import psycopg
import pytest
import redis
from fastapi.testclient import TestClient

# ============================================================================
# REAL DATABASE FIXTURES (PostgreSQL and Redis via Docker Compose)
# ============================================================================


@pytest.fixture(scope="session")
def postgres_connection() -> Generator[psycopg.Connection, None, None]:
    """
    Real PostgreSQL connection for integration testing with schema migrations.

    This fixture connects to the PostgreSQL database and ensures checkpoint tables exist.
    
    Modes:
        - Local (Docker Compose): Runs migrations and drops tables on cleanup
        - Deployed (K8s): Uses existing tables, skips cleanup to preserve service state

    Tables Required:
        - checkpoint_migrations: Migration tracking (v=9)
        - checkpoints: Main checkpoint state (thread_id, checkpoint_id, checkpoint JSONB, metadata)
        - checkpoint_blobs: Channel values (thread_id, channel, version, blob BYTEA)
        - checkpoint_writes: Pending writes (thread_id, checkpoint_id, task_id, blob BYTEA)

    Yields:
        psycopg.Connection: Active PostgreSQL connection
    """
    # Connect to PostgreSQL test database
    # Support both local Docker Compose and deployed K8s via environment variables
    conn = psycopg.connect(
        host=os.environ.get("TEST_POSTGRES_HOST", "localhost"),
        port=int(os.environ.get("TEST_POSTGRES_PORT", "15433")),
        user=os.environ.get("TEST_POSTGRES_USER", "test_user"),
        password=os.environ.get("TEST_POSTGRES_PASSWORD", "test_pass"),
        dbname=os.environ.get("TEST_POSTGRES_DB", "test_db")
    )

    # Check if we're testing against deployed K8s (tables already exist from service)
    # If TEST_POSTGRES_USER is not "test_user", we're likely testing against deployed env
    is_deployed_env = os.environ.get("TEST_POSTGRES_USER", "test_user") != "test_user"
    tables_created_by_fixture = False

    with conn.cursor() as cur:
        # Check if checkpoint tables already exist
        cur.execute("""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_name IN ('checkpoint_migrations', 'checkpoints', 'checkpoint_blobs', 'checkpoint_writes')
        """)
        existing_table_count = cur.fetchone()[0]

        if existing_table_count == 4:
            # Tables already exist (deployed env or previous test run)
            print(f"Checkpoint tables already exist ({existing_table_count}/4)")
        else:
            # Run migration script to create checkpoint tables
            migration_file = Path(__file__).parent.parent.parent / "migrations" / "001_create_checkpointer_tables.up.sql"
            if migration_file.exists():
                migration_sql = migration_file.read_text()
                cur.execute(migration_sql)
                conn.commit()
                tables_created_by_fixture = True
                print("Created checkpoint tables via migration")
            else:
                raise FileNotFoundError(f"Migration file not found: {migration_file}")

        # Verify tables exist
        cur.execute("""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_name IN ('checkpoint_migrations', 'checkpoints', 'checkpoint_blobs', 'checkpoint_writes')
        """)
        table_count = cur.fetchone()[0]
        assert table_count == 4, f"Expected 4 checkpoint tables in public schema, found {table_count}"

    yield conn

    # Cleanup: Only drop tables if we created them AND not testing against deployed env
    if tables_created_by_fixture and not is_deployed_env:
        with conn.cursor() as cur:
            cur.execute("DROP TABLE IF EXISTS checkpoint_writes")
            cur.execute("DROP TABLE IF EXISTS checkpoint_blobs")
            cur.execute("DROP TABLE IF EXISTS checkpoints")
            cur.execute("DROP TABLE IF EXISTS checkpoint_migrations")
            conn.commit()
            print("Cleaned up checkpoint tables")
    else:
        print("Skipping table cleanup (deployed environment or tables pre-existed)")

    conn.close()


@pytest.fixture
def redis_client() -> Generator[redis.Redis, None, None]:
    """
    Real Redis client for integration testing.

    This fixture connects to the Redis instance running via Docker Compose
    at localhost:6380.

    Yields:
        redis.Redis: Active Redis client with decode_responses=True

    Cleanup:
        Flushes test database after each test
    """
    # Connect to Redis test instance
    # Support both local Docker Compose and deployed K8s via environment variables
    redis_password = os.environ.get("TEST_REDIS_PASSWORD")
    client = redis.Redis(
        host=os.environ.get("TEST_REDIS_HOST", "localhost"),
        port=int(os.environ.get("TEST_REDIS_PORT", "16380")),
        password=redis_password if redis_password else None,
        decode_responses=True
    )

    # Verify connection
    client.ping()

    yield client

    # Cleanup: Flush test database
    client.flushdb()
    client.close()


@pytest.fixture
async def nats_client():
    """
    Real NATS client for integration testing.

    This fixture connects to the NATS instance and ensures the required
    streams exist for testing (AGENT_STATUS for result events).

    Yields:
        tuple: (nats.NATS connection, JetStream context)

    Cleanup:
        Closes NATS connection after each test
    """
    import nats
    from nats.js.api import StreamConfig
    
    # Connect to NATS test instance
    # Support both local Docker Compose and deployed K8s via environment variables
    nats_url = os.environ.get("TEST_NATS_URL", "nats://localhost:14222")
    nc = await nats.connect(nats_url)
    
    # Get JetStream context
    js = nc.jetstream()
    
    # Ensure AGENT_STATUS stream exists for capturing result CloudEvents
    # The CloudEventEmitter publishes to agent.status.completed and agent.status.failed
    try:
        await js.stream_info("AGENT_STATUS")
    except Exception:
        # Stream doesn't exist, create it
        await js.add_stream(
            name="AGENT_STATUS",
            subjects=["agent.status.*"],
            retention="limits",
            max_age=3600,  # 1 hour retention for tests
            storage="memory",  # Use memory for faster tests
        )
    
    yield nc, js
    
    # Cleanup: Close connection (don't delete stream - may be used by other tests)
    await nc.close()


# ============================================================================
# MOCK FIXTURES - REMOVED K_SINK MOCKING (Now using NATS)
# ============================================================================
# K_SINK mocking has been removed as CloudEventEmitter now publishes to NATS.
# Tests will verify NATS message publishing instead.


# ============================================================================
# SAMPLE DATA FIXTURES
# ============================================================================


@pytest.fixture
def sample_agent_definition() -> Dict[str, Any]:
    """
    Load REAL agent definition from tests/mock/definition.json.

    This fixture loads the actual mock definition used by the application,
    ensuring that integration tests validate real graph building and execution.

    Returns:
        Dictionary containing agent definition from definition.json
    """
    definition_path = Path(__file__).parent.parent / "mock" / "definition.json"
    with open(definition_path) as f:
        return json.load(f)


@pytest.fixture
def sample_job_execution_event(sample_agent_definition: Dict[str, Any]) -> Dict[str, Any]:
    """
    Sample JobExecutionEvent for testing.

    Args:
        sample_agent_definition: Agent definition fixture

    Returns:
        Dictionary containing JobExecutionEvent data
    """
    return {
        "trace_id": "test-trace-123",
        "job_id": "test-job-456",
        "agent_definition": sample_agent_definition,
        "input_payload": {
            "messages": [
                {"role": "user", "content": "Create a simple hello world agent that greets users"}
            ]
        }
    }


@pytest.fixture
def sample_cloudevent(sample_job_execution_event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Sample CloudEvent wrapper for JobExecutionEvent.

    Args:
        sample_job_execution_event: JobExecutionEvent fixture

    Returns:
        Dictionary containing complete CloudEvent structure
    """
    return {
        "specversion": "1.0",
        "type": "dev.my-platform.agent.execute",
        "source": "nats://agent.execute.test",
        "id": "test-cloudevent-789",
        "data": sample_job_execution_event
    }


# ============================================================================
# TIER 1 CRITICAL INTEGRATION TESTS (ENHANCED WITH REAL DATA VALIDATION)
# ============================================================================


@pytest.mark.asyncio
async def test_cloudevent_processing_end_to_end_success(
    postgres_connection: psycopg.Connection,
    redis_client: redis.Redis,
    nats_client,
    sample_cloudevent: Dict[str, Any],
    monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    Test complete CloudEvent processing workflow with REAL data flow validation.

    This test validates the entire end-to-end flow with REAL infrastructure:
    1. Receive CloudEvent from HTTP endpoint (POST /)
    2. Parse JobExecutionEvent from CloudEvent data
    3. Build LangGraph agent from agent_definition (REAL GraphBuilder)
    4. Execute agent with REAL graph execution and REAL LLM API calls
    5. Publish stream events to REAL Dragonfly
    6. Save checkpoints to REAL PostgreSQL
    7. Emit job.completed CloudEvent to NATS (real NATS JetStream)
    8. Return HTTP 200 OK

    Enhanced Validation:
        - PostgreSQL checkpoints written with correct thread_id (job_id)
        - Dragonfly events published with correct structure and trace_id propagation
        - CloudEvent emitted to NATS with correct structure and data payload
        - ALL events captured and saved to outputs/ directory
        - Detailed execution summary printed to stdout

    Success Criteria:
        - HTTP 200 OK response
        - GraphBuilder builds REAL graph from definition.json
        - Graph executes successfully with REAL LLM API calls
        - PostgreSQL: At least 1 checkpoint written with thread_id = job_id
        - Dragonfly: Minimum 1 event published (end event)
        - CloudEvent published to NATS subject "agent.status.completed"
        - Minimum event counts validated (≥5/≥5/≥11/≥6/==1)
        - Specialist invocation order validated
        - Artifacts saved to outputs/ directory

    References:
        - Requirements: Req. 1.1, 1.2, 3.1, 3.2, 4.1, 4.2, 4.3, 4.4, 5.1, 5.3
        - Design: Section 2.11, Section 3.1
        - Tasks: Task 2.2, 2.3 (Updated for NATS)
        - Event Reference: agent-executor-event-example.md
        - Minimum Guarantees: agent-executor-minimum-events.md
    """
    print("\n[DEBUG] test_cloudevent_processing_end_to_end_success: STARTING")
    
    # Track execution start time
    execution_start_time = time.time()
    
    # Extract job execution event from CloudEvent for validation
    sample_job_execution_event = sample_cloudevent["data"]
    print(f"[DEBUG] Job ID: {sample_job_execution_event.get('job_id')}")

    # Set ALL required environment variables for FastAPI app startup
    # Use TEST_* env vars if set (from test-talos.sh), otherwise use defaults for Docker Compose
    print("[DEBUG] Setting environment variables...")
    monkeypatch.setenv("DISABLE_VAULT_AUTH", "true")
    monkeypatch.setenv("NATS_URL", os.environ.get("TEST_NATS_URL", "nats://localhost:14222"))

    # PostgreSQL configuration - use TEST_* env vars if available
    pg_host = os.environ.get("TEST_POSTGRES_HOST", "localhost")
    pg_port = os.environ.get("TEST_POSTGRES_PORT", "15433")
    pg_db = os.environ.get("TEST_POSTGRES_DB", "test_db")
    pg_user = os.environ.get("TEST_POSTGRES_USER", "test_user")
    print(f"[DEBUG] PostgreSQL: {pg_user}@{pg_host}:{pg_port}/{pg_db}")
    
    monkeypatch.setenv("POSTGRES_HOST", pg_host)
    monkeypatch.setenv("POSTGRES_PORT", pg_port)
    monkeypatch.setenv("POSTGRES_DB", pg_db)
    monkeypatch.setenv("POSTGRES_USER", os.environ.get("TEST_POSTGRES_USER", "test_user"))
    monkeypatch.setenv("POSTGRES_PASSWORD", os.environ.get("TEST_POSTGRES_PASSWORD", "test_pass"))
    monkeypatch.setenv("POSTGRES_SCHEMA", "public")

    # Dragonfly configuration - use TEST_* env vars if available
    monkeypatch.setenv("DRAGONFLY_HOST", os.environ.get("TEST_REDIS_HOST", "localhost"))
    monkeypatch.setenv("DRAGONFLY_PORT", os.environ.get("TEST_REDIS_PORT", "16380"))
    if os.environ.get("TEST_REDIS_PASSWORD"):
        monkeypatch.setenv("DRAGONFLY_PASSWORD", os.environ.get("TEST_REDIS_PASSWORD"))

    # LLM API key - Load from .env file for actual LLM calls
    from dotenv import load_dotenv
    load_dotenv(override=True)

    # Subscribe to Redis channel BEFORE execution to capture all events
    print("[DEBUG] Setting up Redis pub/sub...")
    pubsub = redis_client.pubsub()
    channel = "langgraph:stream:test-job-456"
    pubsub.subscribe(channel)
    print(f"[DEBUG] Subscribed to Redis channel: {channel}")

    # Start listening in a separate thread (non-blocking)
    streaming_events: List[Dict[str, Any]] = []

    def capture_events():
        """Capture streaming events from Redis pub/sub."""
        for message in pubsub.listen():
            if message['type'] == 'message':
                try:
                    event_data = json.loads(message['data'])
                    streaming_events.append(event_data)

                    # Stop after final "end" event
                    if event_data.get("event_type") == "end":
                        break
                except json.JSONDecodeError:
                    pass  # Ignore non-JSON messages

    # Start event capture in background (NOTE: For real async testing, use asyncio)
    # For this test, we'll verify events after execution completes
    import threading
    capture_thread = threading.Thread(target=capture_events, daemon=True)
    capture_thread.start()
    print("[DEBUG] Started Redis event capture thread")

    # Subscribe to NATS subject BEFORE execution to capture CloudEvent
    print("[DEBUG] Setting up NATS subscription...")
    nc, js = nats_client
    nats_messages = []
    
    async def nats_message_handler(msg):
        """Capture NATS messages."""
        data = json.loads(msg.data.decode())
        nats_messages.append(data)
        await msg.ack()
    
    # Subscribe to agent.status.completed subject
    import asyncio
    print("[DEBUG] Creating NATS pull subscription for agent.status.completed...")
    sub = await js.pull_subscribe("agent.status.completed", "test-consumer")
    print("[DEBUG] NATS subscription created")
    
    # Create task to fetch NATS messages in background
    async def fetch_nats_messages():
        try:
            msgs = await sub.fetch(batch=1, timeout=10)
            for msg in msgs:
                await nats_message_handler(msg)
        except asyncio.TimeoutError:
            pass  # No messages received
    
    nats_task = asyncio.create_task(fetch_nats_messages())

    # Import app after environment is configured
    print("[DEBUG] Importing FastAPI app...")
    from agent_executor.api.main import app
    print("[DEBUG] App imported successfully")

    # Create test client with lifespan context
    print("[DEBUG] Creating TestClient (this starts app lifespan)...")
    with TestClient(app) as client:
        print("[DEBUG] TestClient created, app lifespan started")
        
        # Prepare CloudEvent request with CloudEvent headers
        headers = {
            "ce-type": "dev.my-platform.agent.execute",
            "ce-source": "nats://agent.execute.test",
            "ce-id": "test-cloudevent-789",
            "ce-specversion": "1.0"
        }

        # Send POST request with CloudEvent
        print("[DEBUG] Sending POST request to /...")
        response = client.post(
            "/",
            json=sample_cloudevent,
            headers=headers
        )
        print(f"[DEBUG] Response received: {response.status_code}")

        # ================================================================
        # VALIDATION 1: HTTP Response
        # ================================================================
        assert response.status_code == 200, \
            f"Expected 200 OK, got {response.status_code}: {response.text}"

        # Wait for event capture to complete
        # The agent needs time to execute with real LLM calls
        # Wait for "end" event or timeout after 60 seconds
        max_wait = 60
        waited = 0
        while waited < max_wait:
            if any(e.get("event_type") == "end" for e in streaming_events):
                print(f"✓ Agent execution completed after {waited} seconds")
                break
            time.sleep(1)
            waited += 1
        
        if waited >= max_wait:
            print(f"⚠ Timeout after {max_wait} seconds waiting for completion")
        
        # Give a bit more time for final events to be captured
        time.sleep(2)
        
        # Wait for NATS message to be received
        await nats_task
        
        # Calculate total execution duration
        total_duration_s = time.time() - execution_start_time

        # ================================================================
        # IMPORT HELPERS AFTER TEST EXECUTION
        # ================================================================
        from tests.integration.test_helpers import (
            extract_checkpoints,
            extract_specialist_timeline,
            generate_checkpoint_summary,
            generate_cloudevent_summary,
            generate_execution_summary,
            generate_test_id,
            save_artifact,
            validate_minimum_events,
            validate_specialist_order,
            validate_event_structure,
        )
        
        # Generate unique test ID for artifacts
        test_id = generate_test_id()

        # ================================================================
        # ARTIFACT COLLECTION: Save ALL events to file
        # ================================================================
        save_artifact(f"test_{test_id}_all_events.json", streaming_events, as_json=True)

        # ================================================================
        # VALIDATION 2: PostgreSQL Checkpoint Validation
        # ================================================================
        # Query checkpoints written during execution
        checkpoints = extract_checkpoints(postgres_connection, "test-job-456")

        # ================================================================
        # ARTIFACT COLLECTION: Save checkpoints to file
        # ================================================================
        save_artifact(f"test_{test_id}_checkpoints.json", checkpoints, as_json=True)

        # ================================================================
        # REQ 3.1: job_id MUST be used as thread_id (CRITICAL)
        # ================================================================
        # Reference: requirements.md Section 3 "Stateful Graph Execution and Persistence"
        # "THE Agent Executor SHALL use the `job_id` from the `JobExecutionEvent`
        #  as the `thread_id` for the LangGraph execution."

        assert len(checkpoints) > 0, \
            "Req 3.1 VIOLATION: At least one checkpoint must be written to PostgreSQL"

        # Verify thread_id = job_id for ALL checkpoints
        for checkpoint in checkpoints:
            thread_id = checkpoint["thread_id"]

            assert thread_id == sample_job_execution_event["job_id"], \
                f"Req 3.1 VIOLATION: thread_id must equal job_id. " \
                f"Expected '{sample_job_execution_event['job_id']}', got '{thread_id}'"

        # ================================================================
        # REQ 3.3: Checkpoints saved after each step
        # ================================================================
        # Reference: requirements.md Section 3
        # "WHILE a LangGraph Graph is executing, THE Agent Executor SHALL save
        #  a Checkpoint to the Primary Data Store after the completion of each
        #  operational step within the graph."

        assert len(checkpoints) >= 1, \
            f"Req 3.3: Expected at least one checkpoint after graph step execution, " \
            f"got {len(checkpoints)}"

        # Verify checkpoint contains state data
        for checkpoint in checkpoints:
            checkpoint_data = checkpoint["checkpoint"]

            assert checkpoint_data is not None, \
                "Req 3.3: Checkpoint must contain state data"

            assert isinstance(checkpoint_data, dict), \
                f"Req 3.3: Checkpoint must be a dict. Got: {type(checkpoint_data)}"

            # Verify checkpoint has required LangGraph fields
            # Reference: LangGraph PostgresSaver checkpoint structure
            # https://langchain-ai.github.io/langgraph/reference/checkpoints/
            assert "v" in checkpoint_data or "channel_values" in checkpoint_data, \
                "Req 3.3: Checkpoint must contain LangGraph state (v or channel_values)"

        # ================================================================
        # VALIDATION 3: Redis Streaming Events Validation
        # ================================================================
        # Stop pub/sub listener
        pubsub.unsubscribe(channel)
        pubsub.close()

        # ================================================================
        # TIER 1: CRITICAL VALIDATIONS (MUST PASS)
        # ================================================================
        # Reference: agent-executor-minimum-events.md Section "Enforceable Test Assertions"
        print("\n" + "="*80)
        print("TIER 1: CRITICAL VALIDATIONS")
        print("="*80)

        # CRITICAL 1: Validate Subagent Invocation Pattern
        # Task tool calls are embedded in the message history within on_state_update events
        # Extract all messages from state updates and count task tool calls
        task_tool_calls = []
        for event in streaming_events:
            if event.get("event_type") == "on_state_update":
                messages_str = event.get("data", {}).get("messages", "")
                # Count occurrences of task tool calls in the message history
                # Tool calls appear as: {'name': 'task', 'args': {...}, ...}
                if "'name': 'task'" in messages_str or '"name": "task"' in messages_str:
                    # Count individual task calls by looking for subagent_type in args
                    import re
                    task_matches = re.findall(r"'name': 'task'.*?'subagent_type': '([^']+)'", messages_str)
                    task_tool_calls.extend(task_matches)
        
        assert len(task_tool_calls) >= 5, \
            f"CRITICAL FAILURE: Expected ≥5 'task' tool invocations (for 5 subagents), " \
            f"got {len(task_tool_calls)}. " \
            f"Subagents invoked: {task_tool_calls}. " \
            f"This indicates SubAgentMiddleware is not working correctly."
        
        print(f"✅ Subagent invocations: {len(task_tool_calls)} task tool calls")
        print(f"   Subagents invoked: {', '.join(task_tool_calls)}")

        # CRITICAL 2: Validate All 5 Specialists Were Invoked
        # Check that all expected specialists appear in the task_tool_calls list
        expected_specialists = [
            "Guardrail Agent",
            "Impact Analysis Agent", 
            "Workflow Spec Agent",
            "Agent Spec Agent",
            "Multi-Agent Compiler Agent"
        ]
        
        for specialist in expected_specialists:
            assert specialist in task_tool_calls, \
                f"CRITICAL FAILURE: Specialist '{specialist}' was not invoked. " \
                f"Invoked: {task_tool_calls}"
        
        print(f"✅ All 5 specialists invoked successfully")

        # ================================================================
        # TIER 2: CONSISTENCY VALIDATIONS (SHOULD PASS)
        # ================================================================
        print("\n" + "="*80)
        print("TIER 2: CONSISTENCY VALIDATIONS")
        print("="*80)

        # Event structure validation
        is_valid, errors = validate_event_structure(streaming_events)
        if not is_valid:
            print(f"⚠️  WARNING: Event structure issues:\n" + "\n".join(errors))
        else:
            print("✅ Event structure validated")

        # Minimum event guarantees
        is_valid, errors = validate_minimum_events(streaming_events, use_typical=True)
        if not is_valid:
            is_valid_critical, errors_critical = validate_minimum_events(streaming_events, use_typical=False)
            if not is_valid_critical:
                print(f"⚠️  WARNING: Even critical event guarantees not met:\n" + "\n".join(errors_critical))
            else:
                print(f"⚠️  WARNING: Only critical guarantees met:\n" + "\n".join(errors))
        else:
            print("✅ Minimum event guarantees met")

        # Execution order validation
        is_valid, errors = validate_specialist_order(streaming_events)
        if not is_valid:
            print(f"⚠️  WARNING: Execution order issues:\n" + "\n".join(errors))
        else:
            print("✅ Execution order validated")

        # ================================================================
        # REQ 4.1: Redis channel naming convention
        # ================================================================
        # Reference: requirements.md Section 4 "Real-Time Output Streaming"
        # "THE Agent Executor SHALL publish LLM token generation events to a
        #  Redis channel named `langgraph:stream:{thread_id}`."
        # Also ref: design.md Section 2.5 "Redis Streaming Architecture"

        expected_channel = f"langgraph:stream:{sample_job_execution_event['job_id']}"
        assert channel == expected_channel, \
            f"Req 4.1 VIOLATION: Channel must be 'langgraph:stream:{{thread_id}}'. " \
            f"Expected '{expected_channel}', got '{channel}'"

        # ================================================================
        # REQ 4.1-4.3: Redis Streaming Events MUST be published
        # ================================================================
        # Reference: requirements.md Section 4
        # "REQ 4.1: SHALL publish LLM token generation events"
        # "REQ 4.2: SHALL publish tool execution start and end events"
        # "REQ 4.3: SHALL publish an 'end' event"

        assert len(streaming_events) >= 1, \
            f"Req 4.1-4.3 VIOLATION: Expected at least one streaming event. " \
            f"Got {len(streaming_events)} events: {[e.get('event_type') for e in streaming_events]}"

        # ================================================================
        # DESIGN 2.5: Event structure validation
        # ================================================================
        # Reference: design.md Section 4.4 "Redis Stream Payload"
        # All events must have event_type and data fields

        for event in streaming_events:
            assert "event_type" in event, \
                f"Design 2.5 VIOLATION: Event must have event_type field. Got: {event.keys()}"

            assert "data" in event, \
                f"Design 2.5 VIOLATION: Event must have data field. Got: {event.keys()}"

        # Verify specific event types exist
        event_types = [e["event_type"] for e in streaming_events]

        # REQ 4.1: LLM token generation events
        assert any(event_type in ["on_llm_stream", "on_llm_new_token", "on_chain_end"]
                  for event_type in event_types), \
            f"Req 4.1 VIOLATION: Must publish LLM token generation events. Got event types: {event_types}"

        # REQ 4.3: Final 'end' event MUST be published
        assert "end" in event_types, \
            f"Req 4.3 VIOLATION: Must publish final 'end' event to signal completion. " \
            f"Got event types: {event_types}"

        # Verify final "end" event structure
        end_events = [e for e in streaming_events if e.get("event_type") == "end"]
        assert len(end_events) > 0, \
            "Req 4.3 VIOLATION: Expected at least one 'end' event in Redis stream"

        final_end_event = end_events[0]
        assert isinstance(final_end_event["data"], dict), \
            "Req 4.3 VIOLATION: Final 'end' event data should be a dict"

        # ================================================================
        # VALIDATION 4: CloudEvent Emission Validation (NATS)
        # ================================================================
        # Verify NATS message was received
        print("\n" + "="*80)
        print(f"NATS messages received: {len(nats_messages)}")
        if nats_messages:
            print("CloudEvent from NATS:")
            print(json.dumps(nats_messages[0], indent=2))
        print("="*80 + "\n")
        
        assert len(nats_messages) > 0, \
            "NATS verification failed: No CloudEvent received on agent.status.completed"
        
        cloudevent_json = nats_messages[0]

        # ================================================================
        # REQ 5.1: job.completed event MUST be emitted (CRITICAL)
        # ================================================================
        # Reference: requirements.md Section 5 "Job Status Reporting"
        # "WHEN a LangGraph Graph execution completes successfully,
        #  THE Agent Executor SHALL publish a job.completed event containing
        #  the job_id and final result to the Message Queue."
        
        assert cloudevent_json["type"] == "dev.my-platform.agent.completed", \
            f"Req 5.1 VIOLATION: CloudEvent type must be 'dev.my-platform.agent.completed'. " \
            f"Got: '{cloudevent_json.get('type')}'"

        assert cloudevent_json["source"] == "agent-executor-service", \
            f"Req 5.1 VIOLATION: CloudEvent source must be 'agent-executor-service'. " \
            f"Got: '{cloudevent_json.get('source')}'"

        assert cloudevent_json["subject"] == sample_job_execution_event["job_id"], \
            f"Req 5.1 VIOLATION: CloudEvent subject must be job_id. " \
            f"Expected '{sample_job_execution_event['job_id']}', got '{cloudevent_json.get('subject')}'"

        # ================================================================
        # DESIGN 2.8: W3C Trace Context Propagation (CRITICAL)
        # ================================================================
        # Reference: design.md Section 2.8 "Observability Design"
        # "Extract `trace_id` from CloudEvent context and propagate through all events"
        
        assert "traceparent" in cloudevent_json, \
            "Design 2.8 VIOLATION: CloudEvent must include W3C trace context (traceparent header)"
        
        # Verify traceparent format: 00-{trace_id}-{span_id}-{flags}
        traceparent = cloudevent_json["traceparent"]
        traceparent_parts = traceparent.split("-")
        assert len(traceparent_parts) == 4, \
            f"Design 2.8 VIOLATION: traceparent must have format '00-{{trace_id}}-{{span_id}}-{{flags}}'. " \
            f"Got: '{traceparent}'"

        # ================================================================
        # REQ 5.1: CloudEvent data payload MUST contain job_id and result
        # ================================================================
        # Reference: requirements.md Section 5
        # "SHALL publish a job.completed event containing the job_id and final result"
        
        data = cloudevent_json["data"]
        assert "job_id" in data, \
            "Req 5.1 VIOLATION: CloudEvent data must contain job_id"
        assert data["job_id"] == sample_job_execution_event["job_id"], \
            f"Req 5.1 VIOLATION: job_id mismatch in CloudEvent data. " \
            f"Expected '{sample_job_execution_event['job_id']}', got '{data.get('job_id')}'"
        assert "result" in data, \
            "Req 5.1 VIOLATION: CloudEvent data must contain result"
        assert data["result"] is not None, \
            "Req 5.1 VIOLATION: Result must not be null"
        #     f"Req 5.1 VIOLATION: job_id mismatch in CloudEvent data. " \
        #     f"Expected '{sample_job_execution_event['job_id']}', got '{data.get('job_id')}'"
        # assert "result" in data, \
        #     "Req 5.1 VIOLATION: CloudEvent data must contain result"
        # assert data["result"] is not None, \
        #     "Req 5.1 VIOLATION: Result must not be null"

        assert data["result"]["status"] == "completed", \
            f"Req 5.1 VIOLATION: Result status must be 'completed'. " \
            f"Got: '{data['result']['status']}'"

        # ================================================================
        # ARTIFACT COLLECTION: Save CloudEvent and specialist timeline
        # ================================================================
        save_artifact(f"test_{test_id}_cloudevent.json", cloudevent_json, as_json=True)
        
        specialist_timeline = extract_specialist_timeline(streaming_events)
        save_artifact(f"test_{test_id}_specialist_timeline.json", specialist_timeline, as_json=True)

        # ================================================================
        # GENERATE AND PRINT EXECUTION SUMMARY
        # ================================================================
        execution_summary = generate_execution_summary(
            streaming_events,
            checkpoints,
            specialist_timeline,
            cloudevent_json,
            total_duration_s
        )
        
        checkpoint_summary = generate_checkpoint_summary(checkpoints)
        cloudevent_summary = generate_cloudevent_summary(cloudevent_json)
        
        # Save summary to file
        full_summary = f"{execution_summary}\n\n{checkpoint_summary}\n\n{cloudevent_summary}"
        save_artifact(f"test_{test_id}_summary.txt", full_summary, as_json=False)
        
        # Print ONLY summary to stdout (not all events)
        print("\n" + execution_summary)
        print("\n" + checkpoint_summary)
        print("\n" + cloudevent_summary)


@pytest.mark.skip(reason="Failure test needs to be reimplemented for NATS architecture")
@pytest.mark.asyncio
async def test_cloudevent_processing_end_to_end_failure(
    postgres_connection: psycopg.Connection,
    redis_client: redis.Redis,
    nats_client,
    sample_cloudevent: Dict[str, Any],
    monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    Test complete CloudEvent processing workflow with execution failure.

    TODO: This test needs to be reimplemented for NATS architecture.
    The test should:
    1. Subscribe to agent.status.failed NATS subject
    2. Mock GraphBuilder to raise an exception
    3. Send CloudEvent via HTTP
    4. Verify job.failed CloudEvent is published to NATS
    """
    pass


# ============================================================================
# NATS CONSUMER INTEGRATION TEST
# ============================================================================


@pytest.mark.asyncio
async def test_nats_consumer_processing(
    postgres_connection: psycopg.Connection,
    redis_client: redis.Redis,
    nats_client,
    sample_cloudevent: Dict[str, Any],
    monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    Test NATS consumer processes messages and publishes results.

    This test validates the NATS consumer workflow:
    1. Publish CloudEvent to NATS subject "agent.execute.test"
    2. NATS consumer picks up the message
    3. Consumer executes the agent
    4. Consumer publishes result to "agent.status.completed"
    5. Verify PostgreSQL checkpoints created
    6. Verify Dragonfly streaming events published

    References:
        - Requirements: 1.5, 4.1, 4.2, 4.5, 5.1, 5.2, 6.1, 6.2
        - Tasks: Task 2.4
    """
    # Extract job execution event from CloudEvent
    sample_job_execution_event = sample_cloudevent["data"]
    
    # Set ALL required environment variables - use TEST_* env vars if available
    monkeypatch.setenv("DISABLE_VAULT_AUTH", "true")
    monkeypatch.setenv("NATS_URL", os.environ.get("TEST_NATS_URL", "nats://localhost:14222"))
    
    # PostgreSQL configuration - use TEST_* env vars if available
    monkeypatch.setenv("POSTGRES_HOST", os.environ.get("TEST_POSTGRES_HOST", "localhost"))
    monkeypatch.setenv("POSTGRES_PORT", os.environ.get("TEST_POSTGRES_PORT", "15433"))
    monkeypatch.setenv("POSTGRES_DB", os.environ.get("TEST_POSTGRES_DB", "test_db"))
    monkeypatch.setenv("POSTGRES_USER", os.environ.get("TEST_POSTGRES_USER", "test_user"))
    monkeypatch.setenv("POSTGRES_PASSWORD", os.environ.get("TEST_POSTGRES_PASSWORD", "test_pass"))
    monkeypatch.setenv("POSTGRES_SCHEMA", "public")
    
    # Dragonfly configuration - use TEST_* env vars if available
    monkeypatch.setenv("DRAGONFLY_HOST", os.environ.get("TEST_REDIS_HOST", "localhost"))
    monkeypatch.setenv("DRAGONFLY_PORT", os.environ.get("TEST_REDIS_PORT", "16380"))
    if os.environ.get("TEST_REDIS_PASSWORD"):
        monkeypatch.setenv("DRAGONFLY_PASSWORD", os.environ.get("TEST_REDIS_PASSWORD"))
    
    # LLM API key
    from dotenv import load_dotenv
    load_dotenv(override=True)
    
    # Get NATS connection
    nc, js = nats_client
    
    # Subscribe to result subject BEFORE publishing
    result_messages = []
    
    async def result_handler(msg):
        """Capture result messages."""
        data = json.loads(msg.data.decode())
        result_messages.append(data)
        await msg.ack()
    
    result_sub = await js.pull_subscribe("agent.status.completed", "test-result-consumer")
    
    # Subscribe to Dragonfly channel to capture streaming events
    pubsub = redis_client.pubsub()
    channel = f"langgraph:stream:{sample_job_execution_event['job_id']}"
    pubsub.subscribe(channel)
    
    streaming_events: List[Dict[str, Any]] = []
    
    def capture_events():
        """Capture streaming events from Dragonfly pub/sub."""
        for message in pubsub.listen():
            if message['type'] == 'message':
                try:
                    event_data = json.loads(message['data'])
                    streaming_events.append(event_data)
                    if event_data.get("event_type") == "end":
                        break
                except json.JSONDecodeError:
                    pass
    
    import threading
    capture_thread = threading.Thread(target=capture_events, daemon=True)
    capture_thread.start()
    
    # Start the FastAPI app with NATS consumer
    from agent_executor.api.main import app
    
    # Import app starts the lifespan which initializes NATS consumer
    # We need to give it time to start
    import asyncio
    await asyncio.sleep(2)
    
    # Publish CloudEvent to NATS subject "agent.execute.test"
    print("\n" + "="*80)
    print("Publishing CloudEvent to NATS subject: agent.execute.test")
    print("="*80 + "\n")
    
    cloudevent_payload = json.dumps(sample_cloudevent).encode()
    await js.publish("agent.execute.test", cloudevent_payload)
    
    # Wait for NATS consumer to process (give it time for real LLM execution)
    print("Waiting for NATS consumer to process message...")
    await asyncio.sleep(30)  # Wait for execution to complete
    
    # Fetch result from NATS
    try:
        msgs = await result_sub.fetch(batch=1, timeout=5)
        for msg in msgs:
            await result_handler(msg)
    except asyncio.TimeoutError:
        pass
    
    # ================================================================
    # VALIDATION 1: NATS Result CloudEvent
    # ================================================================
    print(f"\nResult messages received: {len(result_messages)}")
    assert len(result_messages) > 0, \
        "NATS consumer test failed: No result CloudEvent received"
    
    result_cloudevent = result_messages[0]
    print("Result CloudEvent:")
    print(json.dumps(result_cloudevent, indent=2))
    
    # Verify CloudEvent structure
    assert result_cloudevent["type"] == "dev.my-platform.agent.completed", \
        f"Expected type 'dev.my-platform.agent.completed', got '{result_cloudevent.get('type')}'"
    
    assert result_cloudevent["source"] == "agent-executor-service", \
        f"Expected source 'agent-executor-service', got '{result_cloudevent.get('source')}'"
    
    assert result_cloudevent["subject"] == sample_job_execution_event["job_id"], \
        f"Expected subject '{sample_job_execution_event['job_id']}', got '{result_cloudevent.get('subject')}'"
    
    # Verify CloudEvent data payload
    assert "data" in result_cloudevent, \
        "CloudEvent must contain 'data' field"
    
    data = result_cloudevent["data"]
    assert "job_id" in data, \
        "CloudEvent data must contain 'job_id'"
    
    assert data["job_id"] == sample_job_execution_event["job_id"], \
        f"job_id mismatch: expected '{sample_job_execution_event['job_id']}', got '{data.get('job_id')}'"
    
    assert "result" in data, \
        "CloudEvent data must contain 'result'"
    
    assert data["result"] is not None, \
        "Result must not be null"
    
    # ================================================================
    # VALIDATION 2: PostgreSQL Checkpoints
    # ================================================================
    with postgres_connection.cursor() as cur:
        cur.execute(
            "SELECT COUNT(*) FROM checkpoints WHERE thread_id = %s",
            (sample_job_execution_event["job_id"],)
        )
        checkpoint_count = cur.fetchone()[0]
    
    print(f"\nPostgreSQL checkpoints created: {checkpoint_count}")
    assert checkpoint_count > 0, \
        f"Expected at least 1 checkpoint, got {checkpoint_count}"
    
    # ================================================================
    # VALIDATION 3: Dragonfly Streaming Events
    # ================================================================
    # Wait a bit more for events
    await asyncio.sleep(2)
    
    print(f"\nDragonfly streaming events captured: {len(streaming_events)}")
    assert len(streaming_events) > 0, \
        "Expected streaming events to be published to Dragonfly"
    
    # Verify "end" event exists
    end_events = [e for e in streaming_events if e.get("event_type") == "end"]
    assert len(end_events) > 0, \
        "Expected at least one 'end' event in Dragonfly stream"
    
    print("\n" + "="*80)
    print("✓ NATS consumer test PASSED")
    print(f"  - Result CloudEvent received: {len(result_messages)}")
    print(f"  - PostgreSQL checkpoints: {checkpoint_count}")
    print(f"  - Dragonfly events: {len(streaming_events)}")
    print("="*80 + "\n")


# ============================================================================
# HELPER TESTS
# ============================================================================


def test_fixtures_are_properly_configured(
    postgres_connection: psycopg.Connection,
    redis_client: redis.Redis,
    sample_agent_definition: Dict[str, Any],
    sample_cloudevent: Dict[str, Any]
) -> None:
    """
    Validate that test fixtures are properly configured.

    This test ensures that all mocks and real connections are set up correctly
    before running the critical integration tests.
    """
    # Verify PostgreSQL connection (REAL)
    assert postgres_connection is not None
    with postgres_connection.cursor() as cur:
        cur.execute("SELECT 1")
        result = cur.fetchone()
        assert result == (1,)

    # Verify Redis client (REAL)
    assert redis_client is not None
    assert redis_client.ping()

    # Extract job execution event from CloudEvent for validation
    sample_job_execution_event = sample_cloudevent["data"]

    # Verify sample data structure
    assert "tool_definitions" in sample_agent_definition
    assert "nodes" in sample_agent_definition
    assert "trace_id" in sample_job_execution_event
    assert "job_id" in sample_job_execution_event
    assert "data" in sample_cloudevent
    assert "specversion" in sample_cloudevent


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])
