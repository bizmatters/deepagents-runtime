"""
Test the pre_work tool.
"""
import os
import tempfile
from pathlib import Path


def test_pre_work_tool():
    """Test the pre_work tool with a temporary filesystem."""
    # Import the tool
    from tests.mock.tools.pre_work import pre_work
    
    # Create a temporary directory for testing
    with tempfile.TemporaryDirectory() as tmpdir:
        original_cwd = os.getcwd()
        os.chdir(tmpdir)
        
        try:
            # Test 1: Guardrail Agent - missing user_request.md
            result = pre_work.invoke({"agent_name": "Guardrail Agent", "files": {}})
            assert "✗ PRE-WORK FAILED" in result
            assert "user_request.md" in result
            print("✅ Test 1 passed: Missing prerequisite detected")
            
            # Test 2: Guardrail Agent - user_request.md exists
            files_state = {
                "/user_request.md": {
                    "content": ["Create a hello world agent\n"],
                    "created_at": "2024-01-01T00:00:00Z",
                    "modified_at": "2024-01-01T00:00:00Z"
                }
            }
            
            result = pre_work.invoke({"agent_name": "Guardrail Agent", "files": files_state})
            assert "✓ PRE-WORK PASSED" in result
            print("✅ Test 2 passed: Prerequisites verified")
            
            # Test 3: Impact Analysis Agent - missing guardrail_assessment.md
            result = pre_work.invoke({"agent_name": "Impact Analysis Agent", "files": files_state})
            assert "✗ PRE-WORK FAILED" in result
            assert "guardrail_assessment.md" in result
            print("✅ Test 3 passed: Multiple prerequisites check works")
            
            # Test 4: Impact Analysis Agent - all prerequisites exist
            files_state["/guardrail_assessment.md"] = {
                "content": ["# Guardrail Assessment\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = pre_work.invoke({"agent_name": "Impact Analysis Agent", "files": files_state})
            assert "✓ PRE-WORK PASSED" in result
            print("✅ Test 4 passed: All prerequisites verified")
            
            # Test 5: Workflow Spec Agent - missing impact_assessment.md
            result = pre_work.invoke({"agent_name": "Workflow Spec Agent", "files": files_state})
            assert "✗ PRE-WORK FAILED" in result
            assert "impact_assessment.md" in result
            print("✅ Test 5 passed: Workflow Spec prerequisites check")
            
            # Test 6: Multi-Agent Compiler - missing all spec files
            result = pre_work.invoke({"agent_name": "Multi-Agent Compiler Agent", "files": files_state})
            assert "✗ PRE-WORK FAILED" in result
            assert "requirements.md" in result or "plan.md" in result
            print("✅ Test 6 passed: Compiler prerequisites check")
            
            # Test 7: Multi-Agent Compiler - create all prerequisites
            files_state["/impact_assessment.md"] = {
                "content": ["# Impact\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            files_state["/THE_SPEC/requirements.md"] = {
                "content": ["# Requirements\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            files_state["/THE_SPEC/plan.md"] = {
                "content": ["# Plan\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            files_state["/THE_SPEC/constitution.md"] = {
                "content": ["# Constitution\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            files_state["/THE_CAST/agent.md"] = {
                "content": ["# Agent\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = pre_work.invoke({"agent_name": "Multi-Agent Compiler Agent", "files": files_state})
            assert "✓ PRE-WORK PASSED" in result
            print("✅ Test 7 passed: All compiler prerequisites verified")
            
            # Test 8: Invalid agent name
            result = pre_work.invoke({"agent_name": "Invalid Agent", "files": {}})
            assert "Error: Unknown agent name" in result
            print("✅ Test 8 passed: Invalid agent name handled")
            
        finally:
            os.chdir(original_cwd)
    
    print("\n✅ All 8 pre_work tool tests passed!")


if __name__ == "__main__":
    test_pre_work_tool()
