"""
Unit tests for CloudEventEmitter service.

Tests the CloudEvent emission logic for job completion and failure notifications,
including K_SINK configuration validation, CloudEvent construction, HTTP posting,
and trace context propagation.

References:
    - Requirements: Req. 5.1, 5.2, 5.3, 5.4, NFR-4.2
    - Implementation: agent_executor/services/cloudevents.py
"""

import os
from typing import Any, Dict
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from cloudevents.http import CloudEvent

from agent_executor.services.cloudevents import CloudEventEmitter


class TestCloudEventEmitterInitialization:
    """Tests for CloudEventEmitter initialization and K_SINK configuration."""

    def test_init_success_with_k_sink(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Test successful initialization when K_SINK is configured."""
        monkeypatch.setenv("K_SINK", "http://broker.knative.svc.cluster.local")

        emitter = CloudEventEmitter()

        assert emitter.k_sink_url == "http://broker.knative.svc.cluster.local"

    def test_init_strips_whitespace_from_k_sink(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Test that K_SINK value is stripped of leading/trailing whitespace."""
        monkeypatch.setenv("K_SINK", "  http://broker.knative.svc.cluster.local  ")

        emitter = CloudEventEmitter()

        assert emitter.k_sink_url == "http://broker.knative.svc.cluster.local"

    def test_init_raises_when_k_sink_missing(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Test that ValueError is raised when K_SINK is not set."""
        monkeypatch.delenv("K_SINK", raising=False)

        with pytest.raises(ValueError, match="K_SINK environment variable is not configured"):
            CloudEventEmitter()

    def test_init_raises_when_k_sink_empty(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Test that ValueError is raised when K_SINK is empty string."""
        monkeypatch.setenv("K_SINK", "")

        with pytest.raises(ValueError, match="K_SINK environment variable is not configured"):
            CloudEventEmitter()

    def test_init_raises_when_k_sink_whitespace_only(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Test that ValueError is raised when K_SINK contains only whitespace."""
        monkeypatch.setenv("K_SINK", "   ")

        with pytest.raises(ValueError, match="K_SINK environment variable is not configured"):
            CloudEventEmitter()


class TestCloudEventEmitterEmitCompleted:
    """Tests for emit_completed method."""

    @pytest.fixture
    def emitter(self, monkeypatch: pytest.MonkeyPatch) -> CloudEventEmitter:
        """Create a CloudEventEmitter instance with K_SINK configured."""
        monkeypatch.setenv("K_SINK", "http://broker.knative.svc.cluster.local")
        return CloudEventEmitter()

    @pytest.mark.asyncio
    async def test_emit_completed_success(self, emitter: CloudEventEmitter) -> None:
        """Test successful emission of job.completed CloudEvent."""
        job_id = "uuid-job-123"
        result = {"output": "Task completed successfully", "data": {"key": "value"}}
        trace_id = "uuid-trace-456"

        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_response = MagicMock()
            mock_response.status_code = 200
            mock_client.post.return_value = mock_response
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            await emitter.emit_completed(job_id=job_id, result=result, trace_id=trace_id)

            # Verify HTTP POST was called
            mock_client.post.assert_called_once()
            call_args = mock_client.post.call_args

            # Verify K_SINK URL
            assert call_args[0][0] == "http://broker.knative.svc.cluster.local"

            # Verify headers contain content-type for structured mode
            headers = call_args.kwargs["headers"]
            assert headers["content-type"] == "application/cloudevents+json"

            # Verify body contains CloudEvent attributes (structured mode)
            body = call_args.kwargs["content"]
            import json
            event_data = json.loads(body)
            assert event_data["type"] == "dev.my-platform.agent.completed"
            assert event_data["source"] == "agent-executor-service"
            assert event_data["subject"] == job_id

            # Verify traceparent is in event attributes
            assert "traceparent" in event_data
            assert trace_id.replace("-", "").lower()[:32] in event_data["traceparent"]

            # Verify data payload contains job_id and result
            assert event_data["data"]["job_id"] == "uuid-job-123"
            assert event_data["data"]["result"]["output"] == "Task completed successfully"

    @pytest.mark.asyncio
    async def test_emit_completed_validates_job_id(self, emitter: CloudEventEmitter) -> None:
        """Test that emit_completed raises ValueError for empty job_id."""
        with pytest.raises(ValueError, match="job_id cannot be empty"):
            await emitter.emit_completed(
                job_id="", result={"output": "result"}, trace_id="uuid-trace-123"
            )

    @pytest.mark.asyncio
    async def test_emit_completed_validates_trace_id(self, emitter: CloudEventEmitter) -> None:
        """Test that emit_completed raises ValueError for empty trace_id."""
        with pytest.raises(ValueError, match="trace_id cannot be empty"):
            await emitter.emit_completed(
                job_id="uuid-job-123", result={"output": "result"}, trace_id=""
            )

    @pytest.mark.asyncio
    async def test_emit_completed_handles_http_timeout(self, emitter: CloudEventEmitter) -> None:
        """Test handling of HTTP timeout during CloudEvent POST."""
        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.post.side_effect = httpx.TimeoutException("Request timed out")
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            with pytest.raises(httpx.TimeoutException):
                await emitter.emit_completed(
                    job_id="uuid-job-123",
                    result={"output": "result"},
                    trace_id="uuid-trace-456",
                )

    @pytest.mark.asyncio
    async def test_emit_completed_handles_http_error(self, emitter: CloudEventEmitter) -> None:
        """Test handling of HTTP error status codes during CloudEvent POST."""
        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_response = MagicMock()
            mock_response.status_code = 500
            mock_response.text = "Internal Server Error"
            mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
                "500 Server Error", request=MagicMock(), response=mock_response
            )
            mock_client.post.return_value = mock_response
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            with pytest.raises(httpx.HTTPStatusError):
                await emitter.emit_completed(
                    job_id="uuid-job-123",
                    result={"output": "result"},
                    trace_id="uuid-trace-456",
                )


class TestCloudEventEmitterEmitFailed:
    """Tests for emit_failed method."""

    @pytest.fixture
    def emitter(self, monkeypatch: pytest.MonkeyPatch) -> CloudEventEmitter:
        """Create a CloudEventEmitter instance with K_SINK configured."""
        monkeypatch.setenv("K_SINK", "http://broker.knative.svc.cluster.local")
        return CloudEventEmitter()

    @pytest.mark.asyncio
    async def test_emit_failed_success(self, emitter: CloudEventEmitter) -> None:
        """Test successful emission of job.failed CloudEvent."""
        job_id = "uuid-job-123"
        error = {
            "message": "Tool execution failed: Database timeout",
            "type": "ToolExecutionError",
            "stack_trace": "Traceback (most recent call last):\n  File...",
        }
        trace_id = "uuid-trace-456"

        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_response = MagicMock()
            mock_response.status_code = 200
            mock_client.post.return_value = mock_response
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            await emitter.emit_failed(job_id=job_id, error=error, trace_id=trace_id)

            # Verify HTTP POST was called
            mock_client.post.assert_called_once()
            call_args = mock_client.post.call_args

            # Verify K_SINK URL
            assert call_args[0][0] == "http://broker.knative.svc.cluster.local"

            # Verify headers contain content-type for structured mode
            headers = call_args.kwargs["headers"]
            assert headers["content-type"] == "application/cloudevents+json"

            # Verify body contains CloudEvent attributes (structured mode)
            body = call_args.kwargs["content"]
            import json
            event_data = json.loads(body)
            assert event_data["type"] == "dev.my-platform.agent.failed"
            assert event_data["source"] == "agent-executor-service"
            assert event_data["subject"] == job_id

            # Verify traceparent is in event attributes
            assert "traceparent" in event_data
            assert trace_id.replace("-", "").lower()[:32] in event_data["traceparent"]

            # Verify data payload contains job_id and error details
            assert event_data["data"]["job_id"] == "uuid-job-123"
            assert "Tool execution failed" in event_data["data"]["error"]["message"]

    @pytest.mark.asyncio
    async def test_emit_failed_validates_job_id(self, emitter: CloudEventEmitter) -> None:
        """Test that emit_failed raises ValueError for empty job_id."""
        error = {"message": "Error message"}

        with pytest.raises(ValueError, match="job_id cannot be empty"):
            await emitter.emit_failed(job_id="", error=error, trace_id="uuid-trace-123")

    @pytest.mark.asyncio
    async def test_emit_failed_validates_trace_id(self, emitter: CloudEventEmitter) -> None:
        """Test that emit_failed raises ValueError for empty trace_id."""
        error = {"message": "Error message"}

        with pytest.raises(ValueError, match="trace_id cannot be empty"):
            await emitter.emit_failed(job_id="uuid-job-123", error=error, trace_id="")

    @pytest.mark.asyncio
    async def test_emit_failed_validates_error_structure(self, emitter: CloudEventEmitter) -> None:
        """Test that emit_failed validates error dict contains 'message' field."""
        error_without_message = {"type": "SomeError"}

        with pytest.raises(ValueError, match="error must contain a 'message' field"):
            await emitter.emit_failed(
                job_id="uuid-job-123", error=error_without_message, trace_id="uuid-trace-456"
            )

    @pytest.mark.asyncio
    async def test_emit_failed_handles_http_timeout(self, emitter: CloudEventEmitter) -> None:
        """Test handling of HTTP timeout during failed CloudEvent POST."""
        error = {"message": "Tool execution failed"}

        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.post.side_effect = httpx.TimeoutException("Request timed out")
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            with pytest.raises(httpx.TimeoutException):
                await emitter.emit_failed(
                    job_id="uuid-job-123", error=error, trace_id="uuid-trace-456"
                )


class TestTraceparentGeneration:
    """Tests for W3C Trace Context traceparent header generation."""

    def test_build_traceparent_format(self) -> None:
        """Test that traceparent follows W3C Trace Context format."""
        trace_id = "a1b2c3d4e5f67890abcdef1234567890"

        traceparent = CloudEventEmitter._build_traceparent(trace_id)

        # Format: version-trace_id-parent_id-trace_flags
        parts = traceparent.split("-")
        assert len(parts) == 4
        assert parts[0] == "00"  # Version
        assert parts[1] == trace_id.lower()  # Trace ID (normalized)
        assert len(parts[2]) == 16  # Parent ID (span ID) is 16 hex characters
        assert parts[3] == "01"  # Trace flags (sampled)

    def test_build_traceparent_normalizes_trace_id(self) -> None:
        """Test that traceparent normalizes trace_id (lowercase, no dashes)."""
        trace_id = "A1B2-C3D4-E5F6-7890-ABCD-EF12-3456-7890"

        traceparent = CloudEventEmitter._build_traceparent(trace_id)

        parts = traceparent.split("-")
        assert parts[1] == "a1b2c3d4e5f67890abcdef1234567890"

    def test_build_traceparent_pads_short_trace_id(self) -> None:
        """Test that short trace_id is padded with leading zeros to 32 characters."""
        trace_id = "abc123"

        traceparent = CloudEventEmitter._build_traceparent(trace_id)

        parts = traceparent.split("-")
        assert len(parts[1]) == 32
        assert parts[1] == "00000000000000000000000000abc123"

    def test_build_traceparent_truncates_long_trace_id(self) -> None:
        """Test that overly long trace_id is truncated to 32 characters."""
        trace_id = "a" * 50  # 50 characters

        traceparent = CloudEventEmitter._build_traceparent(trace_id)

        parts = traceparent.split("-")
        assert len(parts[1]) == 32
        assert parts[1] == "a" * 32


class TestCloudEventEmitterIntegration:
    """Integration-style tests for complete CloudEvent emission workflow."""

    @pytest.fixture
    def emitter(self, monkeypatch: pytest.MonkeyPatch) -> CloudEventEmitter:
        """Create a CloudEventEmitter instance with K_SINK configured."""
        monkeypatch.setenv("K_SINK", "http://broker.knative.svc.cluster.local")
        return CloudEventEmitter()

    @pytest.mark.asyncio
    async def test_emit_completed_with_empty_result(self, emitter: CloudEventEmitter) -> None:
        """Test emit_completed allows empty result dictionary."""
        job_id = "uuid-job-123"
        result: Dict[str, Any] = {}  # Empty result is valid
        trace_id = "uuid-trace-456"

        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_response = MagicMock()
            mock_response.status_code = 200
            mock_client.post.return_value = mock_response
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            # Should not raise ValueError
            await emitter.emit_completed(job_id=job_id, result=result, trace_id=trace_id)

            mock_client.post.assert_called_once()

    @pytest.mark.asyncio
    async def test_emit_failed_with_minimal_error(self, emitter: CloudEventEmitter) -> None:
        """Test emit_failed with minimal error structure (only message field)."""
        job_id = "uuid-job-123"
        error = {"message": "Unknown error occurred"}  # Minimal valid error
        trace_id = "uuid-trace-456"

        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_response = MagicMock()
            mock_response.status_code = 200
            mock_client.post.return_value = mock_response
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            # Should not raise ValueError
            await emitter.emit_failed(job_id=job_id, error=error, trace_id=trace_id)

            mock_client.post.assert_called_once()

    @pytest.mark.asyncio
    async def test_emit_completed_request_error(self, emitter: CloudEventEmitter) -> None:
        """Test handling of generic request error during CloudEvent POST."""
        with patch("agent_executor.services.cloudevents.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.post.side_effect = httpx.RequestError("Connection failed")
            mock_client_cls.return_value.__aenter__.return_value = mock_client

            with pytest.raises(httpx.RequestError):
                await emitter.emit_completed(
                    job_id="uuid-job-123",
                    result={"output": "result"},
                    trace_id="uuid-trace-456",
                )
