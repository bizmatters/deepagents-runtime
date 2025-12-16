"""
Test the post_work tool.
"""
import os
import tempfile
import shutil
from pathlib import Path


def test_post_work_tool():
    """Test the post_work tool with a temporary filesystem."""
    # Import the tool
    from tests.mock.tools.post_work import post_work
    
    # Create a temporary directory for testing
    with tempfile.TemporaryDirectory() as tmpdir:
        original_cwd = os.getcwd()
        os.chdir(tmpdir)
        
        try:
            files_state = {}
            
            # Test 1: Missing file - should fail
            result = post_work.invoke({"agent_name": "Guardrail Agent", "files": files_state})
            assert "✗ QC FAILED" in result
            assert "guardrail_assessment.md" in result
            print("✅ Test 1 passed: Correctly detected missing file")
            
            # Test 2: Create the file with valid content - should pass
            files_state["/guardrail_assessment.md"] = {
                "content": ["""# Guardrail Assessment

## Overall Assessment
Status: Approved

## Contextual Guardrails
1. Some guardrail
"""],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = post_work.invoke({"agent_name": "Guardrail Agent", "files": files_state})
            assert "✓ QC PASSED" in result
            print("✅ Test 2 passed: Correctly verified existing file with valid content")
            
            # Test 3: Impact Analysis Agent - missing file
            result = post_work.invoke({"agent_name": "Impact Analysis Agent", "files": files_state})
            assert "✗ QC FAILED" in result
            assert "impact_assessment.md" in result
            print("✅ Test 3 passed: Impact Analysis Agent check works")
            
            # Test 4: Impact Analysis Agent - file exists but missing content
            files_state["/impact_assessment.md"] = {
                "content": ["# Impact Assessment\n\nSome content but missing required strings\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = post_work.invoke({"agent_name": "Impact Analysis Agent", "files": files_state})
            assert "✗ QC FAILED" in result
            assert "Content validation failures" in result
            assert "requirements.md" in result.lower()
            print("✅ Test 4 passed: Content validation detects missing strings")
            
            # Test 5: Impact Analysis Agent - valid content
            files_state["/impact_assessment.md"] = {
                "content": ["""# Impact Assessment

## Constitutional Compliance Analysis
Some analysis here

## File-by-File Implementation Plan

### 1. File: /THE_SPEC/requirements.md
### 2. File: /THE_SPEC/constitution.md  
### 3. File: /THE_SPEC/plan.md
"""],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = post_work.invoke({"agent_name": "Impact Analysis Agent", "files": files_state})
            assert "✓ QC PASSED" in result
            print("✅ Test 5 passed: Valid content passes validation")
            
            # Test 6: Workflow Spec Agent - multiple files
            result = post_work.invoke({"agent_name": "Workflow Spec Agent", "files": files_state})
            assert "✗ QC FAILED" in result
            assert "constitution.md" in result or "plan.md" in result or "requirements.md" in result
            print("✅ Test 6 passed: Multiple file check works")
            
            # Create all required files
            files_state["/THE_SPEC/constitution.md"] = {
                "content": ["# Constitution\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            files_state["/THE_SPEC/plan.md"] = {
                "content": ["# Plan\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            files_state["/THE_SPEC/requirements.md"] = {
                "content": ["# Requirements\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = post_work.invoke({"agent_name": "Workflow Spec Agent", "files": files_state})
            assert "✓ QC PASSED" in result
            print("✅ Test 7 passed: All files verified successfully")
            
            # Test 8: Directory check for Agent Spec Agent - empty
            result = post_work.invoke({"agent_name": "Agent Spec Agent", "files": files_state})
            assert "✗ QC FAILED" in result
            assert "empty" in result.lower()
            print("✅ Test 8 passed: Empty directory detected")
            
            # Test 9: Agent Spec Agent - file without required sections
            files_state["/THE_CAST/test_agent.md"] = {
                "content": ["# Test Agent\n\nSome content\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            result = post_work.invoke({"agent_name": "Agent Spec Agent", "files": files_state})
            assert "✗ QC FAILED" in result
            assert "Content validation failures" in result
            assert "System Prompt" in result or "Tools" in result
            print("✅ Test 9 passed: Missing sections detected in agent files")
            
            # Test 10: Agent Spec Agent - valid file with required sections
            files_state["/THE_CAST/test_agent.md"] = {
                "content": ["""# Test Agent

## System Prompt
You are a test agent.

## Tools
- tool1
- tool2
"""],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            result = post_work.invoke({"agent_name": "Agent Spec Agent", "files": files_state})
            assert "✓ QC PASSED" in result
            print("✅ Test 10 passed: Valid agent file with required sections")
            
            # Test 11: Guardrail Agent - content validation
            files_state["/guardrail_assessment.md"] = {
                "content": ["# Guardrail Assessment\n\nMissing required sections\n"],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = post_work.invoke({"agent_name": "Guardrail Agent", "files": files_state})
            assert "✗ QC FAILED" in result
            assert "Content validation failures" in result
            print("✅ Test 11 passed: Guardrail content validation works")
            
            # Test 12: Guardrail Agent - valid content
            files_state["/guardrail_assessment.md"] = {
                "content": ["""# Guardrail Assessment

## Overall Assessment
Status: Approved

## Contextual Guardrails
1. Guardrail 1
"""],
                "created_at": "2024-01-01T00:00:00Z",
                "modified_at": "2024-01-01T00:00:00Z"
            }
            
            result = post_work.invoke({"agent_name": "Guardrail Agent", "files": files_state})
            assert "✓ QC PASSED" in result
            print("✅ Test 12 passed: Valid guardrail content passes")
            
            # Test 13: Invalid agent name
            result = post_work.invoke({"agent_name": "Invalid Agent", "files": {}})
            assert "Error: Unknown agent name" in result
            print("✅ Test 13 passed: Invalid agent name handled correctly")
            
        finally:
            os.chdir(original_cwd)
    
    print("\n✅ All 13 post_work tool tests passed!")


if __name__ == "__main__":
    test_post_work_tool()
