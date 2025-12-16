"""
Unit tests for GraphBuilder class.

Tests the core graph building functionality using the actual spec definition.json.

References:
    - Requirements: Req. 3.1
    - Design: Section 2.11
    - Tasks: Task 6.6
"""

import json
import pytest
from pathlib import Path
from unittest.mock import Mock

from core.builder import GraphBuilder, GraphBuilderError
from langchain_core.tools import BaseTool


class TestGraphBuilder:
    """Test suite for GraphBuilder class."""

    @pytest.fixture
    def mock_checkpointer(self):
        """Create a mock VaultClient for testing."""
        vault_client = Mock()
        vault_client.get_llm_api_key.return_value = {"api_key": "sk-test-key"}
        return vault_client

    @pytest.fixture
    def builder(self, mock_checkpointer):
        """Create a GraphBuilder instance for testing."""
        return GraphBuilder(checkpointer=None)

    @pytest.fixture
    def spec_definition(self):
        """Load the actual definition.json from specs directory."""
        spec_path = (
            Path(__file__).parent.parent.parent.parent.parent
            / ".kiro/specs/agent-builder/phase1-9-deepagents_runtime_service/definition.json"
        )
        
        if not spec_path.exists():
            # Create a minimal spec definition for testing
            return {
                "name": "test-agent",
                "version": "1.0.0",
                "nodes": [],
                "edges": [],
                "tool_definitions": []
            }
        
        with open(spec_path, 'r') as f:
            return json.load(f)

    def test_initialization(self, mock_checkpointer):
        """Test GraphBuilder initializes with checkpointer."""
        builder = GraphBuilder(checkpointer=None)
        assert builder.checkpointer is None

    def test_build_from_spec_definition(self, builder, spec_definition, monkeypatch):
        """
        Test building a complete graph from the actual spec definition.json.

        This test uses the real definition and validates the graph building process.
        It will fail if dependencies (deepagents, etc.) are not installed, which is expected.

        References:
            - Spec: .kiro/specs/agent-builder/phase1-9-deepagents_runtime_service/definition.json
            - Task: 6.6 (Write unit tests for GraphBuilder)
        """
        # Set a mock API key to allow model instantiation
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test-mock-key-for-unit-testing")

        # Build graph from spec definition
        graph = builder.build_from_definition(spec_definition)

        # Verify graph was created
        assert graph is not None
    
    def test_definition_structure(self, spec_definition):
        """Validate the definition.json structure."""
        # Verify top-level keys
        assert "tool_definitions" in spec_definition
        assert "nodes" in spec_definition
        
        # Verify tool definitions exist
        tool_definitions = spec_definition["tool_definitions"]
        assert len(tool_definitions) > 0
        
        # Verify all tools have required fields
        for tool_def in tool_definitions:
            assert "name" in tool_def
            assert "runtime" in tool_def
            assert "script" in tool_def["runtime"]
        
        # Verify nodes exist
        nodes = spec_definition["nodes"]
        assert len(nodes) > 0
        
        # Verify at least one orchestrator exists
        orchestrator_nodes = [n for n in nodes if n.get("type") == "Orchestrator"]
        assert len(orchestrator_nodes) >= 1
        
        # Verify all nodes have required config
        for node in nodes:
            assert "id" in node
            assert "type" in node
            assert "config" in node
            
            config = node["config"]
            assert "name" in config
            assert "system_prompt" in config
            assert "model" in config
            assert "tools" in config
            
            # Verify model config
            model = config["model"]
            assert "provider" in model
            assert "model" in model


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
