"""
Unit tests for Redis streaming service.

Tests verify:
- Connection establishment with connection pooling
- Stream event publishing with structured logging
- End event publishing
- Error handling for connection and publish failures
- Health check functionality

Requirements Coverage:
- Req. 4.1: Redis connection with connection pooling
- Req. 4.2: Stream event publishing with structured logging
- Req. 4.3: End event publishing
"""

import json
from unittest.mock import MagicMock, Mock, patch

import pytest
import redis

from agent_executor.services.redis import RedisClient


class TestRedisClient:
    """Test suite for RedisClient class."""

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_init_success(self, mock_pool_class: Mock, mock_redis_class: Mock) -> None:
        """
        Test successful Redis client initialization.

        Verifies:
        - Connection pool is created with correct parameters
        - Redis client is initialized with pool
        - Connection is tested with ping()
        - Successful connection is logged

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_pool = MagicMock()
        mock_pool_class.return_value = mock_pool

        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client

        # Create RedisClient
        client = RedisClient(host="redis.test.local", port=6379)

        # Verify connection pool created with correct parameters
        mock_pool_class.assert_called_once_with(
            host="redis.test.local",
            port=6379,
            db=0,
            max_connections=10,
            socket_timeout=5,
            socket_connect_timeout=5,
            decode_responses=True,
        )

        # Verify Redis client created with pool
        mock_redis_class.assert_called_once_with(connection_pool=mock_pool)

        # Verify connection tested
        mock_client.ping.assert_called_once()

        # Verify client properties
        assert client.host == "redis.test.local"
        assert client.port == 6379
        assert client.pool == mock_pool
        assert client.client == mock_client

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_init_connection_failure(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test Redis client initialization with connection failure.

        Verifies:
        - ConnectionError is raised when ping() fails
        - Error is logged with connection details

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_pool = MagicMock()
        mock_pool_class.return_value = mock_pool

        mock_client = MagicMock()
        mock_client.ping.side_effect = redis.ConnectionError("Connection refused")
        mock_redis_class.return_value = mock_client

        # Verify exception raised
        with pytest.raises(redis.ConnectionError):
            RedisClient(host="redis.test.local", port=6379)

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_publish_stream_event_success(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test successful stream event publishing.

        Verifies:
        - Event is published to correct channel format: langgraph:stream:{thread_id}
        - Event payload is correctly serialized to JSON
        - Subscriber count is returned
        - Event is logged with trace_id and job_id

        Requirements: Req. 4.2
        """
        # Setup mocks
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_client.publish.return_value = 5  # 5 subscribers
        mock_redis_class.return_value = mock_client

        # Create client
        client = RedisClient(host="redis.test.local", port=6379)

        # Publish event
        thread_id = "job-123"
        event_type = "on_llm_stream"
        data = {"token": "Hello", "model": "gpt-4"}
        trace_id = "trace-456"
        job_id = "job-123"

        subscriber_count = client.publish_stream_event(
            thread_id=thread_id,
            event_type=event_type,
            data=data,
            trace_id=trace_id,
            job_id=job_id,
        )

        # Verify channel name format
        expected_channel = f"langgraph:stream:{thread_id}"
        expected_payload = {"event_type": event_type, "data": data}
        expected_message = json.dumps(expected_payload)

        mock_client.publish.assert_called_once_with(expected_channel, expected_message)

        # Verify return value
        assert subscriber_count == 5

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_publish_stream_event_types(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test publishing different event types.

        Verifies:
        - on_llm_stream events are published correctly
        - on_tool_start events are published correctly
        - on_tool_end events are published correctly

        Requirements: Req. 4.2
        """
        # Setup mocks
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_client.publish.return_value = 3
        mock_redis_class.return_value = mock_client

        # Create client
        client = RedisClient(host="redis.test.local", port=6379)

        # Test different event types
        test_cases = [
            ("on_llm_stream", {"token": "Test", "model": "gpt-4"}),
            ("on_tool_start", {"tool": "search", "input": {"query": "test"}}),
            ("on_tool_end", {"tool": "search", "output": {"results": []}}),
        ]

        for event_type, data in test_cases:
            client.publish_stream_event(
                thread_id="job-123", event_type=event_type, data=data
            )

            # Verify publish called with correct payload
            expected_payload = {"event_type": event_type, "data": data}
            expected_message = json.dumps(expected_payload)
            mock_client.publish.assert_called_with(
                "langgraph:stream:job-123", expected_message
            )

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_publish_stream_event_serialization_error(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test stream event publishing with JSON serialization error.

        Verifies:
        - JSONDecodeError is raised for non-serializable data
        - Error is logged with channel and event details

        Requirements: Req. 4.2
        """
        # Setup mocks
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client

        # Create client
        client = RedisClient(host="redis.test.local", port=6379)

        # Try to publish non-serializable data
        with patch("agent_executor.services.redis.json.dumps") as mock_dumps:
            mock_dumps.side_effect = json.JSONDecodeError("Invalid", "", 0)

            with pytest.raises(json.JSONDecodeError):
                client.publish_stream_event(
                    thread_id="job-123",
                    event_type="test",
                    data={"key": "value"},
                )

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_publish_stream_event_redis_error(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test stream event publishing with Redis publish error.

        Verifies:
        - RedisError is raised when publish fails
        - Error is logged with channel and event details

        Requirements: Req. 4.2
        """
        # Setup mocks
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_client.publish.side_effect = redis.RedisError("Connection lost")
        mock_redis_class.return_value = mock_client

        # Create client
        client = RedisClient(host="redis.test.local", port=6379)

        # Verify exception raised
        with pytest.raises(redis.RedisError):
            client.publish_stream_event(
                thread_id="job-123", event_type="test", data={"key": "value"}
            )

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_publish_end_event_success(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test successful end event publishing.

        Verifies:
        - End event is published with event_type="end"
        - Data payload is empty dict
        - Channel format is correct
        - Trace and job IDs are passed through

        Requirements: Req. 4.3
        """
        # Setup mocks
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_client.publish.return_value = 3
        mock_redis_class.return_value = mock_client

        # Create client
        client = RedisClient(host="redis.test.local", port=6379)

        # Publish end event
        thread_id = "job-123"
        trace_id = "trace-456"
        job_id = "job-123"

        subscriber_count = client.publish_end_event(
            thread_id=thread_id, trace_id=trace_id, job_id=job_id
        )

        # Verify end event published correctly
        expected_channel = f"langgraph:stream:{thread_id}"
        expected_payload = {"event_type": "end", "data": {}}
        expected_message = json.dumps(expected_payload)

        mock_client.publish.assert_called_once_with(expected_channel, expected_message)
        assert subscriber_count == 3

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_health_check_success(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test successful health check.

        Verifies:
        - ping() is called
        - True is returned when ping succeeds

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client

        # Create client
        client = RedisClient(host="redis.test.local", port=6379)

        # Test health check
        result = client.health_check()

        # Verify ping called twice (once in __init__, once in health_check)
        assert mock_client.ping.call_count == 2
        assert result is True

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_health_check_failure(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test health check failure.

        Verifies:
        - False is returned when ping fails
        - Error is logged

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_client = MagicMock()
        # First ping succeeds (in __init__), second fails (in health_check)
        mock_client.ping.side_effect = [True, redis.RedisError("Connection lost")]
        mock_redis_class.return_value = mock_client

        # Create client
        client = RedisClient(host="redis.test.local", port=6379)

        # Test health check
        result = client.health_check()

        assert result is False

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_close_success(self, mock_pool_class: Mock, mock_redis_class: Mock) -> None:
        """
        Test successful connection close.

        Verifies:
        - Connection pool is disconnected
        - Close is logged

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_pool = MagicMock()
        mock_pool_class.return_value = mock_pool

        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client

        # Create and close client
        client = RedisClient(host="redis.test.local", port=6379)
        client.close()

        # Verify pool disconnected
        mock_pool.disconnect.assert_called_once()

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_close_error(self, mock_pool_class: Mock, mock_redis_class: Mock) -> None:
        """
        Test connection close with error.

        Verifies:
        - Error is caught and logged
        - No exception is raised

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_pool = MagicMock()
        mock_pool.disconnect.side_effect = Exception("Disconnect failed")
        mock_pool_class.return_value = mock_pool

        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client

        # Create and close client (should not raise)
        client = RedisClient(host="redis.test.local", port=6379)
        client.close()  # Should not raise exception

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_context_manager(self, mock_pool_class: Mock, mock_redis_class: Mock) -> None:
        """
        Test context manager protocol.

        Verifies:
        - Client can be used as context manager
        - Connection is closed on exit

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_pool = MagicMock()
        mock_pool_class.return_value = mock_pool

        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client

        # Use as context manager
        with RedisClient(host="redis.test.local", port=6379) as client:
            assert client.host == "redis.test.local"

        # Verify pool disconnected on exit
        mock_pool.disconnect.assert_called_once()

    @patch("agent_executor.services.redis.redis.Redis")
    @patch("agent_executor.services.redis.ConnectionPool")
    def test_custom_connection_parameters(
        self, mock_pool_class: Mock, mock_redis_class: Mock
    ) -> None:
        """
        Test Redis client with custom connection parameters.

        Verifies:
        - Custom max_connections is used
        - Custom timeouts are applied
        - Custom db number is set

        Requirements: Req. 4.1
        """
        # Setup mocks
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client

        # Create client with custom parameters
        client = RedisClient(
            host="redis.test.local",
            port=6380,
            db=2,
            max_connections=20,
            socket_timeout=10,
            socket_connect_timeout=15,
        )

        # Verify pool created with custom parameters
        mock_pool_class.assert_called_once_with(
            host="redis.test.local",
            port=6380,
            db=2,
            max_connections=20,
            socket_timeout=10,
            socket_connect_timeout=15,
            decode_responses=True,
        )
