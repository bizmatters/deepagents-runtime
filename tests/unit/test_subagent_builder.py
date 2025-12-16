"""
Unit tests for subagent builder module.

Tests the subagent compilation functionality.

References:
    - Requirements: Req. 3.1
    - Design: Section 3.2.2
"""

import pytest
from unittest.mock import Mock, patch
from langchain_core.tools import tool as langchain_tool
from langchain_core.runnables import Runnable

from core import build_subagent, SubAgentCompilationError

# Check if deepagents is available
try:
    import deepagents
    DEEPAGENTS_INSTALLED = True
except ImportError:
    DEEPAGENTS_INSTALLED = False


class TestSubagentBuilder:
    """Test suite for subagent builder module."""

    @patch('core.subagent_builder.create_react_agent')
    def test_build_subagent_basic_fallback(self, mock_create_react_agent):
        """Test basic sub-agent compilation with fallback (no deepagents)."""
        mock_agent = Mock(spec=Runnable)
        mock_create_react_agent.return_value = mock_agent

        # Create sample tools
        @langchain_tool
        def sample_tool(query: str) -> str:
            """A sample tool."""
            return query

        available_tools = {"sample_tool": sample_tool}

        specialist_config = {
            "name": "test_specialist",
            "model": {
                "provider": "openai",
                "model_name": "gpt-4o"
            },
            "system_prompt": "You are a test specialist.",
            "tools": ["sample_tool"]
        }

        sub_agent = build_subagent(specialist_config, available_tools)

        assert sub_agent == mock_agent
        mock_create_react_agent.assert_called_once()

        # Verify the call arguments
        call_args = mock_create_react_agent.call_args
        assert call_args[1]["model"] == "openai:gpt-4o"
        assert call_args[1]["prompt"] == "You are a test specialist."
        assert len(call_args[1]["tools"]) == 1

    @patch('core.subagent_builder.create_agent')
    @patch('core.subagent_builder.FilesystemMiddleware')
    @patch('core.subagent_builder.CompiledSubAgent')
    def test_build_subagent_with_deepagents(
        self, mock_compiled_subagent, mock_filesystem_middleware, mock_create_agent
    ):
        """Test sub-agent compilation with deepagents available."""
        mock_agent_runnable = Mock(spec=Runnable)
        mock_create_agent.return_value = mock_agent_runnable

        mock_middleware_instance = Mock()
        mock_filesystem_middleware.return_value = mock_middleware_instance

        mock_subagent_instance = {
            "name": "test",
            "description": "desc",
            "runnable": mock_agent_runnable
        }
        mock_compiled_subagent.return_value = mock_subagent_instance

        # Create sample tools
        @langchain_tool
        def sample_tool(query: str) -> str:
            """A sample tool."""
            return query

        available_tools = {"sample_tool": sample_tool}

        specialist_config = {
            "name": "test_specialist",
            "model": {
                "provider": "openai",
                "model_name": "gpt-4o"
            },
            "system_prompt": "You are a test specialist.",
            "tools": ["sample_tool"]
        }

        sub_agent = build_subagent(specialist_config, available_tools)

        # Should return CompiledSubAgent instance
        assert sub_agent == mock_subagent_instance
        mock_create_agent.assert_called_once()

        # Verify create_agent was called with correct arguments
        call_args = mock_create_agent.call_args
        assert call_args[1]["model"] == "openai:gpt-4o"
        assert call_args[1]["system_prompt"] == "You are a test specialist."
        assert len(call_args[1]["tools"]) == 1

    @patch('core.subagent_builder.create_react_agent')
    def test_build_subagent_no_tools(self, mock_create_react_agent):
        """Test sub-agent compilation with no tools."""
        mock_agent = Mock(spec=Runnable)
        mock_create_react_agent.return_value = mock_agent

        available_tools = {}

        specialist_config = {
            "name": "test_specialist",
            "model": {
                "provider": "openai",
                "model_name": "gpt-4o"
            },
            "system_prompt": "You are a test specialist.",
            "tools": []
        }

        sub_agent = build_subagent(specialist_config, available_tools)

        assert sub_agent == mock_agent
        call_args = mock_create_react_agent.call_args
        assert len(call_args[1]["tools"]) == 0

    @patch('core.subagent_builder.create_react_agent')
    def test_build_subagent_missing_tools(self, mock_create_react_agent):
        """Test sub-agent compilation with missing tools."""
        mock_agent = Mock(spec=Runnable)
        mock_create_react_agent.return_value = mock_agent

        @langchain_tool
        def available_tool(query: str) -> str:
            """An available tool."""
            return query

        available_tools = {"available_tool": available_tool}

        specialist_config = {
            "name": "test_specialist",
            "model": {
                "provider": "openai",
                "model_name": "gpt-4o"
            },
            "system_prompt": "You are a test specialist.",
            "tools": ["available_tool", "missing_tool"]  # missing_tool doesn't exist
        }

        # Should still succeed, but only include available tools
        sub_agent = build_subagent(specialist_config, available_tools)

        assert sub_agent == mock_agent
        call_args = mock_create_react_agent.call_args
        assert len(call_args[1]["tools"]) == 1

    @patch('core.subagent_builder.create_react_agent')
    def test_build_subagent_compilation_error(self, mock_create_react_agent):
        """Test sub-agent compilation handles errors."""
        # Make create_react_agent raise an exception
        mock_create_react_agent.side_effect = Exception("Model initialization failed")

        specialist_config = {
            "name": "test_specialist",
            "model": {"provider": "openai", "model_name": "gpt-4o"},
            "system_prompt": "Test",
            "tools": []
        }

        with pytest.raises(SubAgentCompilationError, match="Failed to compile sub-agent"):
            build_subagent(specialist_config, {})


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
