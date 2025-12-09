"""
Unit tests for model identifier module.

Tests the model identifier creation functionality.

References:
    - Requirements: Req. 3.1
    - Design: Section 3.2.1
"""

import pytest
from agent_executor.core import create_model_identifier


class TestModelIdentifier:
    """Test suite for model identifier creation."""

    def test_create_model_identifier_openai(self):
        """Test model identifier creation for OpenAI."""
        identifier = create_model_identifier("openai", "gpt-4o")
        assert identifier == "openai:gpt-4o"

    def test_create_model_identifier_anthropic(self):
        """Test model identifier creation for Anthropic."""
        identifier = create_model_identifier("anthropic", "claude-3-opus")
        assert identifier == "anthropic:claude-3-opus"

    def test_create_model_identifier_ollama(self):
        """Test model identifier creation for Ollama."""
        identifier = create_model_identifier("ollama", "llama2")
        assert identifier == "ollama:llama2"

    def test_create_model_identifier_empty_provider(self):
        """Test model identifier creation fails with empty provider."""
        with pytest.raises(ValueError, match="Provider name cannot be empty"):
            create_model_identifier("", "gpt-4o")

    def test_create_model_identifier_empty_model(self):
        """Test model identifier creation fails with empty model name."""
        with pytest.raises(ValueError, match="Model name cannot be empty"):
            create_model_identifier("openai", "")

    def test_create_model_identifier_whitespace_handling(self):
        """Test model identifier handles whitespace correctly."""
        identifier = create_model_identifier("  OpenAI  ", "  gpt-4o  ")
        assert identifier == "openai:gpt-4o"

    def test_create_model_identifier_case_normalization(self):
        """Test model identifier normalizes provider to lowercase."""
        identifier = create_model_identifier("OpenAI", "gpt-4o")
        assert identifier == "openai:gpt-4o"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
