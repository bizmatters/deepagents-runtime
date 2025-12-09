"""Core business logic for graph building and execution.

This module provides the main entry point for the agent executor service.
The implementation follows a flat, modular structure:

Flat Structure:
    - builder.py: Main GraphBuilder class (entry point)
    - model_identifier.py: Model identifier creation
    - subagent_builder.py: Subagent compilation logic
    - tool_loader.py: Tool loading logic

Usage:
    from agent_executor.core import GraphBuilder

    builder = GraphBuilder()
    agent = builder.build_from_definition(definition)

Or use the modular functions directly:
    from agent_executor.core import (
        load_tools_from_definition,
        create_model_identifier,
        build_subagent
    )
"""

# Main API
from agent_executor.core.builder import (
    GraphBuilder,
    GraphBuilderError
)

# Modular functions
from agent_executor.core.tool_loader import (
    load_tools_from_definition,
    ToolLoadingError
)
from agent_executor.core.model_identifier import create_model_identifier
from agent_executor.core.subagent_builder import (
    build_subagent,
    SubAgentCompilationError
)

__all__ = [
    # Main API
    "GraphBuilder",
    "GraphBuilderError",

    # Modular functions
    "load_tools_from_definition",
    "create_model_identifier",
    "build_subagent",

    # Exceptions
    "ToolLoadingError",
    "SubAgentCompilationError"
]
