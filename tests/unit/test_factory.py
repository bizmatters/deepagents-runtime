"""
Unit tests for build_agent_from_definition factory function.

Tests the modular factory approach following the spec-engine pattern.
This is the preferred testing approach for the new modular architecture.

References:
    - Requirements: Req. 3.1
    - Design: Section 2.11
    - Tasks: Task 6.6
"""

import pytest
from unittest.mock import Mock, MagicMock, patch
from langchain_core.tools import BaseTool, tool as langchain_tool
from langchain_core.runnables import Runnable

from agent_executor.core import (
    GraphBuilder,
    GraphBuilderError,
    ToolLoadingError,
    SubAgentCompilationError
)

# Check if deepagents is available
try:
    import deepagents
    DEEPAGENTS_INSTALLED = True
except ImportError:
    DEEPAGENTS_INSTALLED = False


class TestBuildAgentFromDefinition:
    """Test suite for build_agent_from_definition factory function."""

    @pytest.fixture
    def mock_vault_client(self):
        """Create a mock VaultClient for testing."""
        vault_client = Mock()
        vault_client.get_llm_api_key.return_value = {
            "api_key": "sk-test-key-12345"
        }
        return vault_client

    @pytest.mark.skipif(not DEEPAGENTS_INSTALLED, reason="deepagents package not installed")
    @patch('agent_executor.core.builder.create_deep_agent')
    @patch('agent_executor.core.subagent_builder.create_agent')
    @patch('agent_executor.core.subagent_builder.FilesystemMiddleware')
    @patch('agent_executor.core.subagent_builder.CompiledSubAgent')
    @patch('agent_executor.core.subagent_builder.DEEPAGENTS_AVAILABLE', True)
    @patch('agent_executor.core.builder.DEEPAGENTS_AVAILABLE', True)
    def test_build_agent_with_deepagents(
        self,
        mock_compiled_subagent,
        mock_filesystem_middleware,
        mock_create_agent,
        mock_create_deep_agent,
        mock_vault_client
    ):
        """Test building agent with deepagents (preferred path)."""
        # Setup mocks
        mock_agent_runnable = Mock(spec=Runnable)
        mock_create_agent.return_value = mock_agent_runnable

        mock_middleware_instance = Mock()
        mock_filesystem_middleware.return_value = mock_middleware_instance

        mock_subagent_instance = {
            "name": "specialist_one",
            "description": "desc",
            "runnable": mock_agent_runnable
        }
        mock_compiled_subagent.return_value = mock_subagent_instance

        mock_deep_agent = Mock(spec=Runnable)
        mock_create_deep_agent.return_value = mock_deep_agent

        # Create definition
        definition = {
            "tool_definitions": [
                {
                    "name": "test_tool",
                    "script": """
from langchain_core.tools import tool

@tool
def test_function(query: str) -> str:
    '''A test tool.'''
    return query

test_tool = test_function
"""
                }
            ],
            "nodes": [
                {
                    "type": "orchestrator",
                    "name": "main_orchestrator",
                    "model": {
                        "provider": "openai",
                        "model_name": "gpt-4o"
                    },
                    "system_prompt": "You are the orchestrator.",
                    "tools": []
                },
                {
                    "type": "specialist",
                    "name": "specialist_one",
                    "model": {
                        "provider": "anthropic",
                        "model_name": "claude-3-opus"
                    },
                    "system_prompt": "You are a specialist.",
                    "tools": ["test_tool"]
                }
            ]
        }

        # Build agent
        builder = GraphBuilder(mock_vault_client)
        agent = builder.build_from_definition(definition)

        # Verify
        assert agent is not None
        assert agent == mock_deep_agent

        # Verify create_deep_agent was called with correct structure
        mock_create_deep_agent.assert_called_once()
        call_args = mock_create_deep_agent.call_args
        assert call_args[1]["model"] == "openai:gpt-4o"
        assert call_args[1]["system_prompt"] == "You are the orchestrator."
        assert "subagents" in call_args[1]
        assert isinstance(call_args[1]["subagents"], list)
        assert len(call_args[1]["subagents"]) == 1

    @patch('agent_executor.core.builder.create_react_agent')
    @patch('agent_executor.core.subagent_builder.create_react_agent')
    @patch('agent_executor.core.subagent_builder.DEEPAGENTS_AVAILABLE', False)
    @patch('agent_executor.core.builder.DEEPAGENTS_AVAILABLE', False)
    def test_build_agent_fallback_mode(
        self,
        mock_subagent_create_react,
        mock_factory_create_react,
        mock_vault_client
    ):
        """Test building agent in fallback mode (no deepagents)."""
        # Setup mocks
        mock_agent = Mock(spec=Runnable)
        mock_subagent_create_react.return_value = mock_agent
        mock_factory_create_react.return_value = mock_agent

        # Create definition
        definition = {
            "tool_definitions": [],
            "nodes": [
                {
                    "type": "orchestrator",
                    "name": "main",
                    "model": {"provider": "openai", "model_name": "gpt-4o"},
                    "system_prompt": "Test orchestrator",
                    "tools": []
                },
                {
                    "type": "specialist",
                    "name": "specialist",
                    "model": {"provider": "openai", "model_name": "gpt-4o"},
                    "system_prompt": "Test specialist",
                    "tools": []
                }
            ]
        }

        # Build agent
        builder = GraphBuilder(mock_vault_client)
        agent = builder.build_from_definition(definition)

        # Verify
        assert agent is not None
        assert mock_subagent_create_react.call_count >= 1

    def test_build_agent_no_nodes(self, mock_vault_client):
        """Test building agent fails with no nodes."""
        definition = {
            "tool_definitions": [],
            "nodes": []
        }

        with pytest.raises(GraphBuilderError, match="must contain at least one node"):
            builder = GraphBuilder(mock_vault_client)
            builder.build_from_definition(definition)

    def test_build_agent_invalid_tool_script(self, mock_vault_client):
        """Test building agent fails with invalid tool script."""
        definition = {
            "tool_definitions": [
                {
                    "name": "bad_tool",
                    "script": "this is invalid python"
                }
            ],
            "nodes": [
                {
                    "type": "orchestrator",
                    "name": "main",
                    "model": {"provider": "openai", "model_name": "gpt-4o"},
                    "system_prompt": "Test",
                    "tools": []
                }
            ]
        }

        with pytest.raises(GraphBuilderError):
            builder = GraphBuilder(mock_vault_client)
            builder.build_from_definition(definition)

    @patch('agent_executor.core.builder.create_react_agent')
    @patch('agent_executor.core.subagent_builder.create_react_agent')
    @patch('agent_executor.core.subagent_builder.DEEPAGENTS_AVAILABLE', False)
    @patch('agent_executor.core.builder.DEEPAGENTS_AVAILABLE', False)
    def test_build_agent_no_orchestrator(
        self,
        mock_subagent_create_react,
        mock_factory_create_react,
        mock_vault_client
    ):
        """Test building agent with no explicit orchestrator uses first node."""
        mock_agent = Mock(spec=Runnable)
        mock_subagent_create_react.return_value = mock_agent
        mock_factory_create_react.return_value = mock_agent

        definition = {
            "tool_definitions": [],
            "nodes": [
                {
                    "type": "specialist",
                    "name": "specialist_one",
                    "model": {"provider": "openai", "model_name": "gpt-4o"},
                    "system_prompt": "You are a specialist.",
                    "tools": []
                }
            ]
        }

        builder = GraphBuilder(mock_vault_client)
        agent = builder.build_from_definition(definition)

        assert agent is not None

    @pytest.mark.skipif(not DEEPAGENTS_INSTALLED, reason="deepagents package not installed")
    @patch('agent_executor.core.builder.create_deep_agent')
    @patch('agent_executor.core.subagent_builder.create_agent')
    @patch('agent_executor.core.subagent_builder.FilesystemMiddleware')
    @patch('agent_executor.core.subagent_builder.CompiledSubAgent')
    @patch('agent_executor.core.subagent_builder.DEEPAGENTS_AVAILABLE', True)
    @patch('agent_executor.core.builder.DEEPAGENTS_AVAILABLE', True)
    def test_build_agent_with_multiple_specialists(
        self,
        mock_compiled_subagent,
        mock_filesystem_middleware,
        mock_create_agent,
        mock_create_deep_agent,
        mock_vault_client
    ):
        """Test building agent with multiple specialists."""
        # Setup mocks
        mock_agent_runnable = Mock(spec=Runnable)
        mock_create_agent.return_value = mock_agent_runnable

        mock_middleware_instance = Mock()
        mock_filesystem_middleware.return_value = mock_middleware_instance

        mock_subagent_instance = Mock()
        mock_subagent_instance.name = "specialist"
        mock_compiled_subagent.return_value = mock_subagent_instance

        mock_deep_agent = Mock(spec=Runnable)
        mock_create_deep_agent.return_value = mock_deep_agent

        # Create definition with multiple specialists
        definition = {
            "tool_definitions": [],
            "nodes": [
                {
                    "type": "orchestrator",
                    "name": "main",
                    "model": {"provider": "openai", "model_name": "gpt-4o"},
                    "system_prompt": "Orchestrator",
                    "tools": []
                },
                {
                    "type": "specialist",
                    "name": "specialist_one",
                    "model": {"provider": "openai", "model_name": "gpt-4o"},
                    "system_prompt": "Specialist 1",
                    "tools": []
                },
                {
                    "type": "specialist",
                    "name": "specialist_two",
                    "model": {"provider": "openai", "model_name": "gpt-4o"},
                    "system_prompt": "Specialist 2",
                    "tools": []
                }
            ]
        }

        # Build agent
        builder = GraphBuilder(mock_vault_client)
        agent = builder.build_from_definition(definition)

        # Verify
        assert agent is not None
        mock_create_deep_agent.assert_called_once()

        # Verify subagents list has 2 specialists
        call_args = mock_create_deep_agent.call_args
        assert len(call_args[1]["subagents"]) == 2


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
