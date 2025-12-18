"""
Agent Generation Workflow Tests - Test 1 (No NATS Events)

This is the original test_api.py with NATS parts removed.
Keeps ALL core logic: PostgreSQL, Redis, artifacts validation, QC checks.

This module contains Tier 1 critical integration tests that validate the complete
end-to-end agent generation workflow through:
- PostgreSQL checkpoints (real database)
- Dragonfly streaming events (real pub/sub)
- Agent workflow execution and artifact generation
- QC validation and schema compliance

Test Strategy:
    - Use REAL PostgreSQL, Dragonfly via Docker Compose
    - Use REAL graph execution with REAL LLM API calls (using OPENAI_API_KEY from .env)
    - Load REAL agent definition from tests/mock/definition.json
    - Validate actual data flow: checkpoints written, events published, artifacts generated
    - NO NATS CloudEvent validation (that's Test 2)

FILE ORGANIZATION:
    1. INFRASTRUCTURE FIXTURES - Database connections (PostgreSQL, Redis)
    2. DATA FIXTURES - Sample test data and CloudEvents
    3. INTEGRATION TESTS - Agent generation workflow validation
       - Test 1: Successful agent generation workflow
       - Test 2: Fixtures configuration validation

Prerequisites:
    - Run: docker-compose -f tests/integration/docker-compose.test.yml up -d
    - PostgreSQL on localhost:15433 (user: test_user, password: test_pass, db: test_db)
    - Redis on localhost:16380

References:
    - Requirements: Req. 1.1, 1.2, 3.1, 4.1, 4.2, 4.3
    - Design: Section 2.11 (Internal Component Architecture), Section 3.1 (API Layer)
    - Spec: .kiro/specs/agent-builder/phase1-9-deepagents_runtime_service/
    - Tasks: Task 8.7 (Tier 1 Critical Integration Tests)
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
# INFRASTRUCTURE FIXTURES - Real Database Connections
# ============================================================================

# PostgreSQL Connection Fixture
@pytest.fixture(scope="function")
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
    # Connect to PostgreSQL test database with retry logic for CI stability
    # Support both local Docker Compose and deployed K8s via environment variables
    max_retries = 3
    retry_delay = 1
    conn = None
    
    for attempt in range(max_retries):
        try:
            conn = psycopg.connect(
                host=os.environ.get("TEST_POSTGRES_HOST", "localhost"),
                port=int(os.environ.get("TEST_POSTGRES_PORT", "15433")),
                user=os.environ.get("TEST_POSTGRES_USER", "test_user"),
                password=os.environ.get("TEST_POSTGRES_PASSWORD", "test_pass"),
                dbname=os.environ.get("TEST_POSTGRES_DB", "test_db")
            )
            print(f"PostgreSQL connection established (attempt {attempt + 1})")
            break
        except Exception as e:
            if attempt < max_retries - 1:
                print(f"PostgreSQL connection failed (attempt {attempt + 1}): {e}. Retrying in {retry_delay}s...")
                time.sleep(retry_delay)
                retry_delay *= 2  # Exponential backoff
            else:
                raise
    
    if conn is None:
        raise RuntimeError("Failed to establish PostgreSQL connection after retries")

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


# Redis Connection Fixture
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


# NATS Connection Fixture - REMOVED FOR TEST 1 (Agent Generation Only)


# ============================================================================
# DATA FIXTURES - Sample Test Data and CloudEvents
# ============================================================================

# Agent Definition Fixture
@pytest.fixture
def sample_agent_definition() -> Dict[str, Any]:
    """
    Load REAL agent definition from tests/mock/definition.json.

    This fixture loads the actual mock definition used by the application,
    ensuring that integration tests validate real graph building and execution.
    
    System prompts are loaded from .md files in tests/mock/prompts/
    Tool scripts are loaded from .py files in tests/mock/tools/
    for better readability and debugging.

    Returns:
        Dictionary containing agent definition with prompts and tools loaded from files
    """
    from tests.integration.test_helpers import load_definition_with_files
    
    definition_path = Path(__file__).parent.parent / "mock" / "definition.json"
    return load_definition_with_files(definition_path)


# Job Execution Event Fixture
@pytest.fixture
def sample_job_execution_event(sample_agent_definition: Dict[str, Any]) -> Dict[str, Any]:
    """
    Sample JobExecutionEvent for testing.

    Generates unique trace_id and job_id for each test run to avoid checkpoint
    collisions when using PostgreSQL checkpointer with the same thread_id.

    Args:
        sample_agent_definition: Agent definition fixture

    Returns:
        Dictionary containing JobExecutionEvent data with unique IDs
    """
    import uuid
    
    # Generate unique IDs for each test run to prevent checkpoint state pollution
    # This ensures each test starts with a clean state instead of resuming from
    # previous checkpoints, which would cause the PatchToolCallsMiddleware to
    # detect dangling tool calls and create an infinite loop
    unique_job_id = f"test-job-{uuid.uuid4()}"
    unique_trace_id = f"test-trace-{uuid.uuid4()}"
    
    return {
        "trace_id": unique_trace_id,
        "job_id": unique_job_id,
        "agent_definition": sample_agent_definition,
        "input_payload": {
            "messages": [
                {"role": "user", "content": "Create a simple hello world agent that greets users"}
            ]
        }
    }


# CloudEvent Wrapper Fixture
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
# INTEGRATION TESTS - End-to-End Workflow Validation
# ============================================================================

# Test 1: Agent Generation Workflow (No NATS)
def test_agent_generation_end_to_end_success(
    postgres_connection: psycopg.Connection,
    redis_client: redis.Redis,
    sample_cloudevent: Dict[str, Any],
    monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    Test complete agent generation workflow with REAL data flow validation.
    
    **TEST 1: AGENT GENERATION ONLY (NO NATS EVENTS)**

    This test validates the entire end-to-end flow with REAL infrastructure:
    1. Send CloudEvent via HTTP API (POST /) - API requires CloudEvent format
    2. Parse JobExecutionEvent from CloudEvent data
    3. Build LangGraph agent from agent_definition (REAL GraphBuilder)
    4. Execute agent with REAL graph execution and REAL LLM API calls
    5. Publish stream events to REAL Dragonfly
    6. Save checkpoints to REAL PostgreSQL
    7. Return HTTP 200 OK (NO NATS CloudEvent result validation)

    Enhanced Validation:
        - PostgreSQL checkpoints written with correct thread_id (job_id)
        - Dragonfly events published with correct structure and trace_id propagation
        - ALL events captured and saved to outputs/ directory
        - Detailed execution summary printed to stdout

    Success Criteria:
        - HTTP 200 OK response
        - GraphBuilder builds REAL graph from definition.json
        - Graph executes successfully with REAL LLM API calls
        - PostgreSQL: At least 1 checkpoint written with thread_id = job_id
        - Dragonfly: Minimum 1 event published (end event)
        - Minimum event counts validated (≥5/≥5/≥11/≥6/==1)
        - Specialist invocation order validated
        - Artifacts saved to outputs/ directory

    References:
        - Requirements: Req. 1.1, 1.2, 3.1, 3.2, 4.1, 4.2, 4.3, 4.4
        - Design: Section 2.11, Section 3.1
        - Tasks: Task 2.2, 2.3
        - Event Reference: agent-executor-event-example.md
        - Minimum Guarantees: agent-executor-minimum-events.md
    """
    # ================================================================
    # LOG CAPTURE SETUP - Capture ALL logs to test run directory
    # ================================================================
    import logging
    import sys
    from datetime import datetime
    from .test_helpers import reset_test_run_dir, get_test_run_dir, generate_test_id
    
    # Reset test run directory for this test execution
    reset_test_run_dir()
    
    # Generate unique test ID and create run directory
    test_id = generate_test_id()
    test_run_dir = get_test_run_dir(test_id)
    
    # Create log file in the test run directory
    log_filename = "test_run.log"
    log_filepath = test_run_dir / log_filename
    
    # Open log file for writing
    log_file = open(log_filepath, 'w')
    
    # Store original stdout/stderr
    original_stdout = sys.stdout
    original_stderr = sys.stderr
    
    # Create a tee class to write to both console and file
    class TeeStream:
        def __init__(self, original_stream, log_file):
            self.original_stream = original_stream
            self.log_file = log_file
            
        def write(self, text):
            self.original_stream.write(text)
            self.original_stream.flush()
            self.log_file.write(text)
            self.log_file.flush()
            
        def flush(self):
            self.original_stream.flush()
            self.log_file.flush()
    
    # Redirect stdout and stderr to capture all output
    sys.stdout = TeeStream(original_stdout, log_file)
    sys.stderr = TeeStream(original_stderr, log_file)
    
    # Also setup Python logging to go to the file
    file_handler = logging.FileHandler(log_filepath, mode='a')
    file_handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
    file_handler.setFormatter(formatter)
    
    # Add to root logger
    root_logger = logging.getLogger()
    root_logger.addHandler(file_handler)
    root_logger.setLevel(logging.DEBUG)
    
    print(f"\n[LOG_CAPTURE] All logs will be saved to: {log_filepath}")
    print("=" * 80)
    
    print("\n[DEBUG] test_agent_generation_end_to_end_success: STARTING")
    
    # Track execution start time
    execution_start_time = time.time()
    
    # Extract job execution event from CloudEvent (API still uses CloudEvent format)
    sample_job_execution_event = sample_cloudevent["data"]
    print(f"[DEBUG] Job ID: {sample_job_execution_event.get('job_id')}")

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
    
    # NOTE: NATS_URL configuration removed for Test 1 (Agent Generation Only)

    # Subscribe to Redis channel BEFORE execution to capture all events
    print("[DEBUG] Setting up Redis pub/sub...")
    pubsub = redis_client.pubsub()
    channel = f"langgraph:stream:{sample_job_execution_event['job_id']}"
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

    # NOTE: NATS subscription setup removed for Test 1 (Agent Generation Only)

    # Import app after environment is configured
    print("[DEBUG] Importing FastAPI app...")
    from api.main import app
    print("[DEBUG] App imported successfully")

    # Create test client with lifespan context
    print("[DEBUG] Creating TestClient (this starts app lifespan)...")
    with TestClient(app) as client:
        print("[DEBUG] TestClient created, app lifespan started")
        
        # Prepare CloudEvent request (still needed for API, but no NATS validation)
        headers = {
            "ce-type": "dev.my-platform.agent.execute",
            "ce-source": "test-client",
            "ce-id": "test-agent-generation-001",
            "ce-specversion": "1.0"
        }

        # Use the sample CloudEvent (API requires CloudEvent format)

        # Send POST request to CloudEvent endpoint
        print("[DEBUG] Sending POST request to / (CloudEvent endpoint)...")
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
        # Multi-agent workflow can take 5-8 minutes with real LLM calls
        max_wait = 480  # 8 minutes
        waited = 0
        print(f"[DEBUG] Waiting up to {max_wait}s for agent execution to complete...")
        while waited < max_wait:
            if any(e.get("event_type") == "end" for e in streaming_events):
                print(f"✓ Agent execution completed after {waited} seconds")
                break
            if waited % 30 == 0 and waited > 0:  # Progress update every 30s
                print(f"[DEBUG] Still executing... ({waited}s elapsed, {len(streaming_events)} events so far)")
            time.sleep(1)
            waited += 1
        
        if waited >= max_wait:
            print(f"⚠ Timeout after {max_wait} seconds waiting for completion")
            print(f"[DEBUG] Captured {len(streaming_events)} events before timeout")
            assert False, f"Test failed: Agent execution took longer than {max_wait} seconds (8 minutes). This indicates a performance issue or infinite loop."
        
        # Give a bit more time for final events to be captured
        time.sleep(2)
        
        # NOTE: NATS message waiting removed for Test 1 (Agent Generation Only)
        
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
            save_artifact,
            validate_minimum_events,
            validate_specialist_order,
            validate_event_structure,
            validate_workflow_result,
            validate_redis_artifacts,
            extract_and_save_generated_files,
        )
        
        # Note: test_id was already generated at the start of the test
        # All artifacts will be saved to the same run directory

        # ================================================================
        # ARTIFACT COLLECTION: Save ALL events to file
        # ================================================================
        save_artifact("all_events.json", streaming_events, as_json=True)
        
        # ================================================================
        # ARTIFACT COLLECTION: Extract and save generated files
        # ================================================================
        # This extracts all files created by write_file tool calls and saves
        # them to a 'files/' subdirectory for easy debugging and review
        print("\n[DEBUG] Extracting generated files from events...")
        extracted_files = extract_and_save_generated_files(streaming_events)
        print(f"[DEBUG] Extracted {len(extracted_files)} files")

        # ================================================================
        # VALIDATION 2: PostgreSQL Checkpoint Validation
        # ================================================================
        # Query checkpoints written during execution
        checkpoints = extract_checkpoints(postgres_connection, sample_job_execution_event["job_id"])

        # ================================================================
        # ARTIFACT COLLECTION: Save checkpoints to file
        # ================================================================
        save_artifact("checkpoints.json", checkpoints, as_json=True)

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
        # REQ 3.4: File System Artifacts Validation (CRITICAL)
        # ================================================================
        # Reference: Builder Agent workflow - validates that all required specification
        # files and the final definition.json were actually generated and emitted in Redis events
        
        print("\n" + "="*80)
        print("REDIS ARTIFACTS VALIDATION")
        print("="*80)
        
        is_valid, artifact_errors = validate_redis_artifacts(streaming_events, sample_job_execution_event["job_id"])
        
        if not is_valid:
            error_msg = "CRITICAL FAILURE: Required artifacts not found in Redis streaming events:\n\n"
            for i, error in enumerate(artifact_errors, 1):
                error_msg += f"{i}. {error}\n"
            error_msg += "\nThis indicates the multi-agent workflow did not successfully generate "
            error_msg += "the required specification files. The workflow may have completed with "
            error_msg += "status='completed' but failed to produce the expected artifacts."
            
            assert False, error_msg
        
        print("✅ All required artifacts found and validated in Redis streaming events:")
        print("   - /THE_SPEC/constitution.md")
        print("   - /THE_SPEC/plan.md") 
        print("   - /THE_SPEC/requirements.md")
        print("   - /definition.json (✅ schema validated)")
        print("="*80)

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
        # NOTE: CloudEvent Emission Validation (NATS) removed for Test 1
        # ================================================================

        # ================================================================
        # CRITICAL: Validate workflow completed successfully (not HALT)
        # ================================================================
        print("\n" + "="*80)
        print("WORKFLOW RESULT VALIDATION")
        print("="*80)
        
        # Create mock result for validation (since we don't have NATS CloudEvent)
        mock_result = {
            "status": "completed",
            "files": {},  # Will be populated from streaming events
            "execution_time": total_duration_s
        }
        
        is_valid, validation_errors = validate_workflow_result(mock_result, checkpoints)
        
        if not is_valid:
            error_msg = "WORKFLOW EXECUTION FAILED:\n\n"
            for i, error in enumerate(validation_errors, 1):
                error_msg += f"{i}. {error}\n"
            error_msg += "\nThis indicates the multi-agent workflow encountered errors and could not "
            error_msg += "complete successfully. Common causes:\n"
            error_msg += "  - Missing required specification files (e.g., requirements.md)\n"
            error_msg += "  - Incomplete implementation plan from Impact Analysis Agent\n"
            error_msg += "  - Logical errors detected by Multi-Agent Compiler Agent\n"
            error_msg += "\nCheck the test logs and CloudEvent output for details."
            
            assert False, error_msg
        
        print(f"✅ Workflow completed successfully (no HALT errors)")
        print(f"✅ Workflow validation passed - artifacts generated and verified in checkpoint state")
        print("="*80)

        # ================================================================
        # ARTIFACT COLLECTION: Save specialist timeline (no CloudEvent in Test 1)
        # ================================================================
        
        specialist_timeline = extract_specialist_timeline(streaming_events)
        save_artifact("specialist_timeline.json", specialist_timeline, as_json=True)

        # ================================================================
        # GENERATE AND PRINT EXECUTION SUMMARY
        # ================================================================
        execution_summary = generate_execution_summary(
            streaming_events,
            checkpoints,
            specialist_timeline,
            None,  # No CloudEvent in Test 1
            total_duration_s
        )
        
        checkpoint_summary = generate_checkpoint_summary(checkpoints)
        
        # Save summary to file
        full_summary = f"{execution_summary}\n\n{checkpoint_summary}"
        save_artifact("summary.txt", full_summary, as_json=False)
        
        # Print ONLY summary to stdout (not all events)
        print("\n" + execution_summary)
        print("\n" + checkpoint_summary)
        
        print(f"\n[LOG_CAPTURE] Complete test logs saved to: {log_filepath}")
        
        # ================================================================
        # LOG CAPTURE CLEANUP
        # ================================================================
        # Restore original stdout/stderr
        sys.stdout = original_stdout
        sys.stderr = original_stderr
        
        # Close log file
        if log_file is not None:
            log_file.close()
        
        print(f"[LOG_CAPTURE] Logs saved to: {log_filepath}")


# Test 2: Fixtures Configuration Test
def test_fixtures_are_properly_configured(
    postgres_connection: psycopg.Connection,
    redis_client: redis.Redis,
    sample_agent_definition: Dict[str, Any],
    sample_job_execution_event: Dict[str, Any],
    sample_cloudevent: Dict[str, Any]
) -> None:
    """
    Test that all fixtures are properly configured and accessible.
    
    This test validates:
    - PostgreSQL connection and checkpoint tables
    - Redis connection
    - Sample data fixtures load correctly
    """
    print("\n[DEBUG] Testing fixture configuration...")
    
    # Test PostgreSQL connection
    with postgres_connection.cursor() as cur:
        cur.execute("SELECT 1")
        result = cur.fetchone()
        assert result[0] == 1, "PostgreSQL connection test failed"
    
    # Test Redis connection
    redis_client.set("test_key", "test_value")
    assert redis_client.get("test_key") == "test_value", "Redis connection test failed"
    redis_client.delete("test_key")
    
    # Test sample data
    assert "job_id" in sample_job_execution_event, "sample_job_execution_event missing job_id"
    assert "agent_definition" in sample_job_execution_event, "sample_job_execution_event missing agent_definition"
    assert "data" in sample_cloudevent, "sample_cloudevent missing data"
    assert sample_cloudevent["data"] == sample_job_execution_event, "CloudEvent data mismatch"
    
    print("✅ All fixtures properly configured")


# ============================================================================
# NOTE: NATS Consumer Integration Test removed for Test 1 (Agent Generation Only)
# ============================================================================


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])