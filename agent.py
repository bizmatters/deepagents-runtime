"""
Agent Executor Graph Factory.

This module provides the factory function for creating agent executor graphs
from definition.json files. It's used by LangGraph CLI for development and testing.

Similar to spec-engine/agent.py, this creates a graph from a test definition
for development purposes.
"""

import json
from pathlib import Path
from typing import Optional

from langgraph.checkpoint.base import BaseCheckpointSaver

from agent_executor.core.builder import GraphBuilder


def create_agent_executor(checkpointer: Optional[BaseCheckpointSaver] = None):
    """
    Creates an agent executor graph from the test definition.
    
    This function loads the test definition.json and builds a graph for
    development and testing purposes. LangGraph CLI automatically provides
    a PostgreSQL checkpointer when POSTGRES_URI is set in the environment.
    
    Args:
        checkpointer: Optional checkpointer instance. LangGraph CLI automatically
                     provides a PostgreSQL checkpointer when POSTGRES_URI is set.
        
    Returns:
        Compiled agent graph ready for execution
    """
    print("🚀 create_agent_executor called!")
    print(f"📦 Checkpointer provided by LangGraph CLI: {checkpointer is not None}")
    print(f"🔧 Checkpointer type: {type(checkpointer) if checkpointer else 'None'}")
    
    # Load test definition
    definition_path = Path(__file__).parent / "tests" / "mock" / "definition.json"
    
    if not definition_path.exists():
        raise FileNotFoundError(
            f"Test definition not found at {definition_path}. "
            "Please ensure tests/mock/definition.json exists."
        )
    
    with open(definition_path) as f:
        definition = json.load(f)
    
    print(f"✓ Loaded definition with {len(definition.get('nodes', []))} nodes")
    
    # Build graph using GraphBuilder (vault_client=None for development)
    builder = GraphBuilder(checkpointer=checkpointer, vault_client=None)
    agent = builder.build_from_definition(definition)
    
    print("✓ Agent graph built successfully")
    return agent
