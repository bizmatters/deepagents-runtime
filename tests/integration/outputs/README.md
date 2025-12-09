# Test Artifacts Output Directory

This directory stores detailed test execution artifacts generated during integration tests.

## Artifact Types

Each test run generates a unique set of artifacts with timestamp-based naming:

### `test_<timestamp>_all_events.json`
Complete capture of ALL streaming events from Redis pub/sub channel.
- Contains every event published during graph execution
- Includes LLM token streams, tool calls, state updates, and end events
- Used for detailed analysis and debugging

### `test_<timestamp>_cloudevent.json`
Final CloudEvent emitted to K_SINK (Knative Broker).
- Contains job completion status
- Includes final agent definition
- Shows W3C trace context propagation

### `test_<timestamp>_checkpoints.json`
PostgreSQL checkpoints written during execution.
- Shows checkpoint timeline
- Validates thread_id = job_id
- Contains LangGraph state snapshots

### `test_<timestamp>_specialist_timeline.json`
Specialist agent execution timeline.
- Start/end timestamps for each specialist
- Duration in milliseconds and seconds
- Execution order validation

### `test_<timestamp>_summary.txt`
Human-readable execution summary.
- Event count breakdown with percentages
- Specialist execution times
- Checkpoint and CloudEvent summaries
- Overall execution statistics

## Usage

Artifacts are automatically generated during test execution:

```bash
# Run integration tests
pytest services/agent_executor/tests/integration/test_api.py -v -s

# View artifacts
ls -lh services/agent_executor/tests/integration/outputs/

# Analyze specific test run
cat services/agent_executor/tests/integration/outputs/test_20241119_143022_summary.txt
```

## Retention

Artifacts are gitignored and not committed to version control. They are useful for:
- Debugging test failures
- Analyzing LLM behavior
- Validating event structure
- Performance analysis

Clean up old artifacts periodically:

```bash
# Remove artifacts older than 7 days
find services/agent_executor/tests/integration/outputs/ -name "test_*.json" -mtime +7 -delete
find services/agent_executor/tests/integration/outputs/ -name "test_*.txt" -mtime +7 -delete
```

## References

- Event structure: `agent-executor-event-example.md`
- Minimum guarantees: `agent-executor-minimum-events.md`
- Test implementation: `test_api.py`
- Helper functions: `test_helpers.py`
