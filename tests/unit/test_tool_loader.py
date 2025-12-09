"""
Unit tests for tool loader module.

Tests the modular tool loading functionality.

References:
    - Requirements: Req. 3.1
    - Design: Section 2.12
"""

import pytest
from langchain_core.tools import BaseTool

from agent_executor.core import load_tools_from_definition, ToolLoadingError


class TestToolLoader:
    """Test suite for tool loader module."""

    def test_load_tools_empty(self):
        """Test loading with empty definitions."""
        tools = load_tools_from_definition([])
        assert tools == {}

    def test_load_tools_simple_tool(self):
        """Test loading a simple tool from script definition."""
        tool_definitions = [
            {
                "name": "test_tool",
                "script": """
from langchain_core.tools import tool

@tool
def test_function(query: str) -> str:
    '''A test tool that returns the query.'''
    return f"Result: {query}"

test_tool = test_function
""",
                "description": "A test tool"
            }
        ]

        tools = load_tools_from_definition(tool_definitions)

        assert "test_tool" in tools
        assert isinstance(tools["test_tool"], BaseTool)

    def test_load_tools_missing_script(self):
        """Test tool loading with missing script field."""
        tool_definitions = [
            {
                "name": "test_tool",
                "description": "A test tool"
                # Missing 'script' field
            }
        ]

        # Should not raise, but should return empty dict
        tools = load_tools_from_definition(tool_definitions)
        assert tools == {}

    def test_load_tools_invalid_script(self):
        """Test tool loading with invalid Python script."""
        tool_definitions = [
            {
                "name": "test_tool",
                "script": "this is not valid python code!!!",
                "description": "A test tool"
            }
        ]

        with pytest.raises(ToolLoadingError, match="Failed to load tool"):
            load_tools_from_definition(tool_definitions)

    def test_load_tools_no_basetool(self):
        """Test tool loading when script doesn't create a BaseTool."""
        tool_definitions = [
            {
                "name": "test_tool",
                "script": """
# This script doesn't create a BaseTool instance
result = 42
""",
                "description": "A test tool"
            }
        ]

        with pytest.raises(ToolLoadingError, match="did not create a BaseTool instance"):
            load_tools_from_definition(tool_definitions)

    def test_load_tools_multiple(self):
        """Test loading multiple tools from definitions."""
        tool_definitions = [
            {
                "name": "tool_one",
                "script": """
from langchain_core.tools import tool

@tool
def tool_one_func(x: str) -> str:
    '''First tool.'''
    return x

tool_one = tool_one_func
""",
            },
            {
                "name": "tool_two",
                "script": """
from langchain_core.tools import tool

@tool
def tool_two_func(y: int) -> int:
    '''Second tool.'''
    return y * 2

tool_two = tool_two_func
""",
            }
        ]

        tools = load_tools_from_definition(tool_definitions)

        assert len(tools) == 2
        assert "tool_one" in tools
        assert "tool_two" in tools


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
