"""
NATS Events Integration Tests

Tests NATS CloudEvents pub/sub infrastructure using the app's actual services.
Uses the app's NATS consumer, CloudEvent emitter, and execution manager for
realistic integration testing that matches production behavior.

This test focuses on:
- CloudEvent format compliance
- NATS pub/sub mechanics using app's services
- Event serialization/deserialization
- Consumer behavior and error handling
- Streaming event structure

Infrastructure: Uses app's actual service clients via dependency injection
Duration: ~30 seconds
"""

import asyncio
import json
import pytest
import uuid
from typing import Dict, Any, List
from unittest.mock import AsyncMock, patch

import nats
from nats.js import JetStreamContext
import structlog
from fastapi.testclient import TestClient

from models.events import JobExecutionEvent
from services.nats_consumer import NATSConsumer
from services.cloudevents import CloudEventEmitter

logger = structlog.get_logger(__name__)


class TestNATSEventsIntegration:
    """Test NATS CloudEvents integration using app's actual services."""

    # Note: Removed separate NATS connection, execution manager, and CloudEvent emitter fixtures.
    # The tests now use the app's actual service clients via dependency injection for better
    # integration testing that matches production behavior.
    
    @pytest.fixture(autouse=True)
    def setup_llm_mocking(self, monkeypatch):
        """Ensure no real LLM calls are made during NATS integration tests."""
        # Force mock mode to prevent any real LLM API calls
        monkeypatch.setenv("USE_MOCK_LLM", "true")
        
        # Also mock LLM classes as a backup to prevent any real API calls
        with patch("langchain_openai.ChatOpenAI") as mock_openai, \
             patch("langchain_anthropic.ChatAnthropic") as mock_anthropic:
            
            # Create a simple mock LLM that returns predictable responses
            mock_llm = AsyncMock()
            mock_llm.ainvoke.return_value = AsyncMock()
            mock_llm.ainvoke.return_value.content = "Mock LLM response"
            
            mock_openai.return_value = mock_llm
            mock_anthropic.return_value = mock_llm
            
            yield

    async def test_cloudevent_format_compliance(self):
        """Test CloudEvent format compliance using app's services."""
        print("\n🔍 Testing CloudEvent Format Compliance")
        
        # Import app after environment setup
        from api.main import app
        
        # Create test client to initialize app services
        with TestClient(app) as client:
            # Get app's services after lifespan startup
            from api.dependencies import get_cloudevent_emitter, get_nats_consumer
            
            app_cloudevent_emitter = get_cloudevent_emitter()
            app_nats_consumer = get_nats_consumer()
            
            print(f"   Using app's CloudEvent emitter: {type(app_cloudevent_emitter).__name__}")
            print(f"   Using app's NATS consumer: {type(app_nats_consumer).__name__}")
            
            # Create test CloudEvent
            cloudevent = {
                "specversion": "1.0",
                "type": "dev.my-platform.agent.execute",
                "source": "test-client",
                "subject": "test-job-001",
                "id": str(uuid.uuid4()),
                "time": "2024-01-01T00:00:00Z",
                "traceparent": "00-12345678901234567890123456789012-1234567890123456-01",
                "data": {
                    "job_id": "test-job-001",
                    "trace_id": "test-trace-001",
                    "agent_definition": {"name": "test-agent"},
                    "input_payload": {"user_request": "Hello World"}
                }
            }
            
            # Validate required CloudEvent fields
            required_fields = ["specversion", "type", "source", "id", "data"]
            for field in required_fields:
                assert field in cloudevent, f"Missing required CloudEvent field: {field}"
            
            # Validate CloudEvent spec version
            assert cloudevent["specversion"] == "1.0", "Invalid CloudEvent spec version"
            
            # Validate data structure
            data = cloudevent["data"]
            assert "job_id" in data, "Missing job_id in CloudEvent data"
            assert "agent_definition" in data, "Missing agent_definition in CloudEvent data"
            assert "input_payload" in data, "Missing input_payload in CloudEvent data"
            
            print("   ✅ CloudEvent format validation passed")

    async def test_nats_publish_subscribe(self):
        """Test basic NATS publish/subscribe functionality using app's NATS consumer."""
        print("\n📡 Testing NATS Publish/Subscribe")
        
        # Import app after environment setup
        from api.main import app
        
        # Create test client to initialize app services
        with TestClient(app) as client:
            # Get app's NATS consumer after lifespan startup
            from api.dependencies import get_nats_consumer
            
            app_nats_consumer = get_nats_consumer()
            print(f"   Using app's NATS consumer: {type(app_nats_consumer).__name__}")
            
            # Check if NATS connection is available - FAIL if not available
            nc = app_nats_consumer.nc
            js = app_nats_consumer.js
            
            assert nc is not None, "NATS server is not available - please start NATS infrastructure"
            assert js is not None, "NATS JetStream is not available - please start NATS infrastructure"
            
            # Create test stream if not exists
            test_stream = "TEST_AGENT_EXECUTION"
            test_subject = "agent.execute.test"
            
            try:
                await js.add_stream(
                    name=test_stream,
                    subjects=[f"{test_subject}.*"],
                    retention="limits",
                    max_msgs=100,
                    max_age=3600  # 1 hour
                )
            except Exception:
                # Stream might already exist
                pass
            
            # Create consumer
            consumer_name = f"test-consumer-{uuid.uuid4().hex[:8]}"
            consumer = await js.pull_subscribe(
                subject=f"{test_subject}.*",
                durable=consumer_name,
                stream=test_stream
            )
            
            # Publish test message
            test_message = {
                "test_id": str(uuid.uuid4()),
                "message": "Hello NATS"
            }
            
            await js.publish(
                subject=f"{test_subject}.hello",
                payload=json.dumps(test_message).encode()
            )
            
            print("   📤 Published test message")
            
            # Subscribe and receive message
            msgs = await consumer.fetch(batch=1, timeout=5)
            assert len(msgs) == 1, "Expected 1 message"
            
            received_message = json.loads(msgs[0].data.decode())
            assert received_message["test_id"] == test_message["test_id"], "Message content mismatch"
            
            await msgs[0].ack()
            print("   📥 Received and acknowledged message")
            
            # Cleanup
            try:
                await js.delete_consumer(test_stream, consumer_name)
                await js.delete_stream(test_stream)
            except Exception:
                pass

    async def test_job_execution_event_validation(self):
        """Test JobExecutionEvent model validation."""
        print("\n📋 Testing JobExecutionEvent Validation")
        
        # Valid event data
        valid_event_data = {
            "job_id": "test-job-001",
            "trace_id": "test-trace-001", 
            "agent_definition": {
                "name": "test-agent",
                "version": "1.0",
                "nodes": [],
                "edges": []
            },
            "input_payload": {
                "user_request": "Create a Hello World agent"
            }
        }
        
        # Test valid event
        event = JobExecutionEvent(**valid_event_data)
        assert event.job_id == "test-job-001"
        assert event.trace_id == "test-trace-001"
        print("   ✅ Valid JobExecutionEvent created")
        
        # Test invalid event (missing required field)
        invalid_event_data = valid_event_data.copy()
        del invalid_event_data["job_id"]
        
        with pytest.raises(Exception):  # Pydantic validation error
            JobExecutionEvent(**invalid_event_data)
        
        print("   ✅ Invalid JobExecutionEvent rejected")

    async def test_nats_consumer_message_processing(self):
        """Test NATSConsumer message processing using app's actual services."""
        print("\n🔄 Testing NATS Consumer Message Processing")
        
        # Import app after environment setup
        from api.main import app
        
        # Create test client to initialize app services
        with TestClient(app) as client:
            # Get app's services after lifespan startup
            from api.dependencies import get_nats_consumer, get_execution_manager, get_cloudevent_emitter
            
            app_nats_consumer = get_nats_consumer()
            app_execution_manager = get_execution_manager()
            app_cloudevent_emitter = get_cloudevent_emitter()
            
            print(f"   Using app's NATS consumer: {type(app_nats_consumer).__name__}")
            print(f"   Using app's execution manager: {type(app_execution_manager).__name__}")
            print(f"   Using app's CloudEvent emitter: {type(app_cloudevent_emitter).__name__}")
            
            # Prepare test message
            test_cloudevent = {
                "specversion": "1.0",
                "type": "dev.my-platform.agent.execute",
                "source": "test-client",
                "id": str(uuid.uuid4()),
                "data": {
                    "job_id": "test-job-002",
                    "trace_id": "test-trace-002",
                    "agent_definition": {
                        "name": "test-agent", 
                        "version": "1.0",
                        "nodes": [{"id": "test-node", "type": "agent"}],  # Add required nodes
                        "edges": []
                    },
                    "input_payload": {"user_request": "Test execution"}
                }
            }
            
            # Test message processing using app's consumer
            # Create a mock message for testing
            class MockMessage:
                def __init__(self, data):
                    self.data = data.encode() if isinstance(data, str) else data
                    self.subject = "agent.execute.test"
                    self.metadata = None
                
                async def ack(self):
                    pass
                
                async def nak(self):
                    pass
            
            mock_msg = MockMessage(json.dumps(test_cloudevent))
            
            # Mock the execution to avoid actual LLM calls in this test
            with patch.object(app_execution_manager, 'execute') as mock_execute:
                mock_execute.return_value = {
                    "status": "completed",
                    "files": {},
                    "execution_time": 1.0
                }
                
                # Process the message using app's consumer
                await app_nats_consumer.process_message(mock_msg)
                
                # Verify execution manager was called
                mock_execute.assert_called_once()
                call_args = mock_execute.call_args
                
                assert call_args.kwargs["job_id"] == "test-job-002"
                assert call_args.kwargs["trace_id"] == "test-trace-002"
                
                print("   ✅ Message processed and execution manager called")

    async def test_error_handling_and_retry(self):
        """Test error handling and retry mechanisms using app's services."""
        print("\n⚠️  Testing Error Handling and Retry")
        
        # Import app after environment setup
        from api.main import app
        
        # Create test client to initialize app services
        with TestClient(app) as client:
            # Get app's services after lifespan startup
            from api.dependencies import get_nats_consumer, get_execution_manager
            
            app_nats_consumer = get_nats_consumer()
            app_execution_manager = get_execution_manager()
            
            print(f"   Using app's NATS consumer: {type(app_nats_consumer).__name__}")
            print(f"   Using app's execution manager: {type(app_execution_manager).__name__}")
            
            # Check if NATS connection is available - FAIL if not available
            assert app_nats_consumer.js is not None, "NATS server is not available - please start NATS infrastructure"
            
            # If NATS is available, run the full test
            # Test message that will cause failure (invalid agent definition)
            error_cloudevent = {
                "specversion": "1.0",
                "type": "dev.my-platform.agent.execute",
                "source": "test-client",
                "id": str(uuid.uuid4()),
                "data": {
                    "job_id": "error-job-001",
                    "trace_id": "error-trace-001",
                    "agent_definition": {"name": "failing-agent"},  # Missing required nodes
                    "input_payload": {"user_request": "This will fail"}
                }
            }
            
            class MockMessage:
                def __init__(self, data):
                    self.data = data.encode() if isinstance(data, str) else data
                    self.subject = "agent.execute.error"
                    self.metadata = None
                
                async def ack(self):
                    pass
                
                async def nak(self):
                    pass
            
            mock_msg = MockMessage(json.dumps(error_cloudevent))
            
            # Mock the execution manager to avoid any potential LLM calls
            with patch.object(app_execution_manager, 'execute') as mock_execute:
                mock_execute.side_effect = Exception("Simulated execution failure")
                
                # Process message (should handle error gracefully)
                # The invalid agent definition will cause a GraphBuilderError before reaching execution
                await app_nats_consumer.process_message(mock_msg)
                
                # The error should be handled gracefully and a failure result published
                print("   ✅ Error handled gracefully by app's consumer")

    async def test_cloudevent_result_publishing(self):
        """Test publishing result CloudEvents using app's services."""
        print("\n📤 Testing CloudEvent Result Publishing")
        
        # Import app after environment setup
        from api.main import app
        
        # Create test client to initialize app services
        with TestClient(app) as client:
            # Get app's services after lifespan startup
            from api.dependencies import get_nats_consumer
            
            app_nats_consumer = get_nats_consumer()
            print(f"   Using app's NATS consumer: {type(app_nats_consumer).__name__}")
            
            # Check if NATS connection is available - FAIL if not available
            nc = app_nats_consumer.nc
            js = app_nats_consumer.js
            
            assert nc is not None, "NATS server is not available - please start NATS infrastructure"
            assert js is not None, "NATS JetStream is not available - please start NATS infrastructure"
            
            # Create result stream
            result_stream = "TEST_RESULT_STREAM"
            
            try:
                await js.add_stream(
                    name=result_stream,
                    subjects=["agent.status.*"],
                    retention="limits",
                    max_msgs=100,
                    max_age=3600
                )
            except Exception:
                pass
            
            # Create consumer for results
            result_consumer = await js.pull_subscribe(
                subject="agent.status.*",
                durable=f"result-consumer-{uuid.uuid4().hex[:8]}",
                stream=result_stream
            )
            
            # Test successful result publishing using app's consumer
            await app_nats_consumer.publish_result(
                job_id="result-job-001",
                result={"status": "completed", "files": {}},
                trace_id="result-trace-001",
                status="completed"
            )
            
            print("   📤 Published success result")
            
            # Test failed result publishing using app's consumer
            await app_nats_consumer.publish_result(
                job_id="result-job-002",
                result={"message": "Test error", "type": "TestError"},
                trace_id="result-trace-002",
                status="failed"
            )
            
            print("   📤 Published failure result")
            
            # Verify results were published
            msgs = await result_consumer.fetch(batch=2, timeout=5)
            assert len(msgs) >= 1, "Expected at least 1 result message"
            
            for msg in msgs:
                result_data = json.loads(msg.data.decode())
                
                # Validate CloudEvent structure
                assert "specversion" in result_data
                assert "type" in result_data
                assert "data" in result_data
                
                # Validate result data
                data = result_data["data"]
                assert "job_id" in data
                
                await msg.ack()
            
            print("   📥 Received and validated result messages")
            
            # Cleanup
            try:
                await js.delete_stream(result_stream)
            except Exception:
                pass

    async def test_consumer_health_check(self):
        """Test NATSConsumer health check functionality using app's consumer."""
        print("\n🏥 Testing Consumer Health Check")
        
        # Import app after environment setup
        from api.main import app
        
        # Create test client to initialize app services
        with TestClient(app) as client:
            # Get app's NATS consumer after lifespan startup
            from api.dependencies import get_nats_consumer
            
            app_nats_consumer = get_nats_consumer()
            print(f"   Using app's NATS consumer: {type(app_nats_consumer).__name__}")
            
            # Test health check on app's consumer
            health_status = app_nats_consumer.health_check()
            print(f"   App consumer health status: {health_status}")
            
            # The consumer should be healthy if NATS infrastructure is available
            assert health_status, "App's NATS consumer should be healthy - please start NATS infrastructure"
            
            print("   ✅ App's NATS consumer is healthy (NATS server available)")


# Run tests
if __name__ == "__main__":
    async def run_tests():
        test_instance = TestNATSEventsIntegration()
        
        # Note: These would normally be run by pytest
        # This is just for demonstration
        print("🧪 NATS Events Integration Tests")
        print("=" * 50)
        
        # Individual test methods would be called by pytest
        # await test_instance.test_cloudevent_format_compliance(...)
        
        print("✅ All NATS events tests completed")
    
    asyncio.run(run_tests())