"""
Verification script for test_helpers.py functionality.

This script tests the helper functions without requiring full integration test setup.
"""

import json
from pathlib import Path

from tests.integration.test_helpers import (
    MINIMUM_GUARANTEES,
    REQUIRED_SPECIALIST_TOOLS,
    SPECIALIST_EXECUTION_ORDER,
    extract_specialist_timeline,
    generate_checkpoint_summary,
    generate_cloudevent_summary,
    generate_execution_summary,
    generate_test_id,
    save_artifact,
    validate_minimum_events,
    validate_specialist_order,
    validate_tool_pairing,
)


def test_constants():
    """Test that constants are properly defined."""
    print("Testing constants...")
    
    assert MINIMUM_GUARANTEES["on_tool_start"] == 5
    assert MINIMUM_GUARANTEES["on_tool_end"] == 5
    assert MINIMUM_GUARANTEES["on_llm_stream"] == 11
    assert MINIMUM_GUARANTEES["on_state_update"] == 6
    assert MINIMUM_GUARANTEES["end"] == 1
    
    assert len(REQUIRED_SPECIALIST_TOOLS) == 5
    assert len(SPECIALIST_EXECUTION_ORDER) == 5
    
    print("✓ Constants are correct")


def test_generate_test_id():
    """Test test ID generation."""
    print("\nTesting test ID generation...")
    
    test_id = generate_test_id()
    assert len(test_id) == 15  # YYYYMMDD_HHMMSS
    assert "_" in test_id
    
    print(f"✓ Generated test ID: {test_id}")


def test_validate_minimum_events():
    """Test minimum event validation."""
    print("\nTesting minimum event validation...")
    
    # Valid events
    valid_events = [
        {"event_type": "on_tool_start"} for _ in range(5)
    ] + [
        {"event_type": "on_tool_end"} for _ in range(5)
    ] + [
        {"event_type": "on_llm_stream"} for _ in range(11)
    ] + [
        {"event_type": "on_state_update"} for _ in range(6)
    ] + [
        {"event_type": "end"}
    ]
    
    is_valid, errors = validate_minimum_events(valid_events)
    assert is_valid, f"Should be valid but got errors: {errors}"
    print("✓ Valid events passed validation")
    
    # Invalid events (missing end event)
    invalid_events = [
        {"event_type": "on_tool_start"} for _ in range(5)
    ]
    
    is_valid, errors = validate_minimum_events(invalid_events)
    assert not is_valid, "Should be invalid"
    assert len(errors) > 0
    print(f"✓ Invalid events correctly rejected: {len(errors)} errors")


def test_validate_specialist_order():
    """Test specialist order validation."""
    print("\nTesting specialist order validation...")
    
    # Correct order
    correct_events = [
        {
            "event_type": "on_tool_start",
            "data": {"tool_name": tool}
        }
        for tool in SPECIALIST_EXECUTION_ORDER
    ]
    
    is_valid, errors = validate_specialist_order(correct_events)
    assert is_valid, f"Should be valid but got errors: {errors}"
    print("✓ Correct order passed validation")
    
    # Wrong order
    wrong_events = [
        {
            "event_type": "on_tool_start",
            "data": {"tool_name": "workflow-spec-agent"}
        },
        {
            "event_type": "on_tool_start",
            "data": {"tool_name": "guardrail-agent"}
        }
    ]
    
    is_valid, errors = validate_specialist_order(wrong_events)
    assert not is_valid, "Should be invalid"
    print(f"✓ Wrong order correctly rejected")


def test_validate_tool_pairing():
    """Test tool start/end pairing validation."""
    print("\nTesting tool pairing validation...")
    
    # Correct pairing
    correct_events = [
        {"event_type": "on_tool_start", "data": {"tool_name": "tool1"}},
        {"event_type": "on_tool_end", "data": {"tool_name": "tool1"}},
        {"event_type": "on_tool_start", "data": {"tool_name": "tool2"}},
        {"event_type": "on_tool_end", "data": {"tool_name": "tool2"}},
    ]
    
    is_valid, errors = validate_tool_pairing(correct_events)
    assert is_valid, f"Should be valid but got errors: {errors}"
    print("✓ Correct pairing passed validation")
    
    # Mismatched pairing
    mismatched_events = [
        {"event_type": "on_tool_start", "data": {"tool_name": "tool1"}},
        {"event_type": "on_tool_start", "data": {"tool_name": "tool2"}},
        {"event_type": "on_tool_end", "data": {"tool_name": "tool1"}},
    ]
    
    is_valid, errors = validate_tool_pairing(mismatched_events)
    assert not is_valid, "Should be invalid"
    print(f"✓ Mismatched pairing correctly rejected")


def test_extract_specialist_timeline():
    """Test specialist timeline extraction."""
    print("\nTesting specialist timeline extraction...")
    
    events = [
        {
            "event_type": "on_tool_start",
            "data": {
                "tool_name": "guardrail-agent",
                "timestamp": "2024-11-19T14:23:45.800Z"
            }
        },
        {
            "event_type": "on_tool_end",
            "data": {
                "tool_name": "guardrail-agent",
                "timestamp": "2024-11-19T14:23:50.800Z",
                "duration_ms": 5000
            }
        }
    ]
    
    timeline = extract_specialist_timeline(events)
    assert len(timeline) == 1
    assert timeline[0]["specialist"] == "guardrail-agent"
    assert timeline[0]["duration_ms"] == 5000
    assert timeline[0]["duration_s"] == 5.0
    
    print(f"✓ Extracted timeline: {timeline[0]}")


def test_save_artifact():
    """Test artifact saving."""
    print("\nTesting artifact saving...")
    
    test_id = generate_test_id()
    test_data = {"test": "data", "count": 123}
    
    filepath = save_artifact(f"test_{test_id}_verification.json", test_data, as_json=True)
    
    assert filepath.exists()
    assert filepath.name == f"test_{test_id}_verification.json"
    
    # Verify content
    with open(filepath) as f:
        loaded_data = json.load(f)
    
    assert loaded_data == test_data
    
    # Clean up
    filepath.unlink()
    
    print(f"✓ Artifact saved and verified: {filepath.name}")


def test_summary_generation():
    """Test summary generation functions."""
    print("\nTesting summary generation...")
    
    # Mock data
    events = [
        {"event_type": "on_llm_stream"} for _ in range(10)
    ] + [
        {"event_type": "on_tool_start"} for _ in range(5)
    ] + [
        {"event_type": "end"}
    ]
    
    checkpoints = [
        {
            "thread_id": "test-job-123",
            "checkpoint_id": f"checkpoint-{i}",
            "checkpoint": {"v": 1},
            "metadata": {}
        }
        for i in range(3)
    ]
    
    specialist_timeline = [
        {
            "specialist": "guardrail-agent",
            "start_timestamp": "2024-11-19T14:23:45.800Z",
            "end_timestamp": "2024-11-19T14:23:50.800Z",
            "duration_ms": 5000,
            "duration_s": 5.0
        }
    ]
    
    cloudevent = {
        "type": "dev.my-platform.agent.completed",
        "subject": "test-job-123",
        "traceparent": "00-abc123def456-7890abcdef12-01",
        "data": {
            "result": {
                "status": "completed",
                "output": "Test output",
                "final_state": {
                    "definition": {
                        "nodes": [{"id": "node1"}, {"id": "node2"}],
                        "edges": [{"source": "START", "target": "node1"}],
                        "tool_definitions": []
                    }
                }
            }
        }
    }
    
    # Generate summaries
    exec_summary = generate_execution_summary(events, checkpoints, specialist_timeline, cloudevent, 10.5)
    checkpoint_summary = generate_checkpoint_summary(checkpoints)
    cloudevent_summary = generate_cloudevent_summary(cloudevent)
    
    assert "EXECUTION SUMMARY" in exec_summary
    assert "10.5s" in exec_summary
    assert "16" in exec_summary  # Total events
    
    assert "POSTGRESQL CHECKPOINTS" in checkpoint_summary
    assert "3 checkpoints" in checkpoint_summary
    
    assert "CLOUDEVENT RESULT" in cloudevent_summary
    assert "completed" in cloudevent_summary
    
    print("✓ All summaries generated successfully")
    print("\nSample Execution Summary:")
    print(exec_summary[:500] + "...")


def main():
    """Run all verification tests."""
    print("=" * 80)
    print("TEST HELPERS VERIFICATION")
    print("=" * 80)
    
    try:
        test_constants()
        test_generate_test_id()
        test_validate_minimum_events()
        test_validate_specialist_order()
        test_validate_tool_pairing()
        test_extract_specialist_timeline()
        test_save_artifact()
        test_summary_generation()
        
        print("\n" + "=" * 80)
        print("✓ ALL VERIFICATION TESTS PASSED")
        print("=" * 80)
        print("\nThe test_helpers.py module is working correctly!")
        print("Ready for integration test execution.")
        
    except AssertionError as e:
        print(f"\n✗ VERIFICATION FAILED: {e}")
        raise


if __name__ == "__main__":
    main()
