# GitHub Actions Integration Tests Proposal

## Overview
This proposal outlines the GitHub Actions workflow for running agent_executor integration tests automatically on each commit.

**Implementation follows the Script Hierarchy Model** (see `bizmatters/.claude/skills/standards/script-hierarchy-model.md`):
- **Tier 1** (`.github/workflows/agent-executor-integration-tests.yml`): Pipeline definition - calls Tier 2 script
- **Tier 2** (`scripts/ci/run-integration-tests.sh`): Task orchestration - calls Tier 3 scripts
- **Tier 3** (`services/agent_executor/scripts/ci/run-tests.sh`): Atomic test execution

## Workflow Files
- **Tier 1**: `.github/workflows/agent-executor-integration-tests.yml`
- **Tier 2**: `scripts/ci/run-integration-tests.sh`
- **Tier 3**: `services/agent_executor/scripts/ci/run-tests.sh`

## Key Features

### 1. Trigger Conditions
- **Push to main**: Runs on commits to main branch
- **Path filtering**: Only triggers when agent_executor code changes
- **Manual trigger**: Can be run manually via workflow_dispatch
- **Note**: PR triggers removed (private repo - no PR workflow needed)

### 2. Infrastructure Management
Uses **docker-compose** to manage test infrastructure (same as local testing):
- **PostgreSQL 15**: Port 15433
- **Dragonfly**: Port 16380 (Redis-compatible)
- **NATS with JetStream**: Port 14222

The Tier 3 script starts/stops services using `docker-compose.test.yml`.

### 3. Test Execution Steps (Script Hierarchy)

#### Tier 1: GitHub Actions Workflow
1. **Checkout Code**: Clone repository
2. **Configure AWS**: Authenticate via OIDC and fetch secrets from Parameter Store
3. **Setup Python**: Install Python 3.11 with pip caching
4. **Execute Tier 2 Script**: Call `scripts/ci/run-integration-tests.sh`
5. **Upload Artifacts**: Test results and coverage reports

#### Tier 2: Orchestration Script (`scripts/ci/run-integration-tests.sh`)
1. **Validate Environment**: Check required environment variables (OPENAI_API_KEY)
2. **Install Dependencies**: Run `poetry install` for Python packages
3. **Run Tests**: Call Tier 3 script `services/agent_executor/scripts/ci/run-tests.sh`

#### Tier 3: Service Script (`services/agent_executor/scripts/ci/run-tests.sh`)
1. **Start Infrastructure**: Run `docker-compose -f tests/integration/docker-compose.test.yml up -d`
2. **Wait for Health**: Wait for PostgreSQL, Dragonfly, NATS to be healthy
3. **Run Migrations**: Apply database migrations using psql
4. **Execute Tests**: Run pytest with integration tests, generate coverage reports
5. **Cleanup**: Run `docker-compose down -v` to remove containers and volumes

**Key Benefit**: Uses the **exact same docker-compose.test.yml** that's used for local testing, ensuring consistency between local and CI environments.

### 4. Environment Variables

**Required (from AWS Parameter Store):**
- `OPENAI_API_KEY`: Fetched from `/zerotouch/prod/agent-executor/openai_api_key`

**Required (from GitHub Secrets):**
- `AWS_ROLE_ARN`: IAM role for OIDC authentication

**Set by Tier 3 Script:**
All test configuration is set inside `run-tests.sh`:
- `POSTGRES_HOST=localhost`, `POSTGRES_PORT=15433`
- `DRAGONFLY_HOST=localhost`, `DRAGONFLY_PORT=16380`
- `NATS_URL=nats://localhost:14222`
- `DISABLE_VAULT_AUTH=true`, `TESTING=true`

## Prerequisites

### 1. AWS IAM Role for GitHub Actions (OIDC)

Create an IAM role that GitHub Actions can assume:

**IAM Role Policy** (allows reading Parameter Store):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
                "ssm:GetParameters",
                "ssm:GetParameter",
                "ssm:PutParameter"
      ],
      "Resource": "arn:aws:ssm:us-east-1:*:parameter/zerotouch/prod/agent-executor/*"
    }
  ]
}
```

**Trust Policy** (allows GitHub Actions to assume role):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:arun4infra/bizmatters:*"
        }
      }
    }
  ]
}
```

### 2. GitHub Repository Secret

Add only ONE secret to your GitHub repository:

1. Go to: `Settings` → `Secrets and variables` → `Actions`
2. Click `New repository secret`
3. Add:
   - **Name**: `AWS_ROLE_ARN`
   - **Value**: `arn:aws:iam::ACCOUNT_ID:role/GitHubActionsRole`

### 3. AWS Parameter Store

Ensure the parameter exists (should already be there for ESO):
```bash
aws ssm get-parameter \
  --name /zerotouch/prod/agent-executor/openai_api_key \
  --with-decryption
```

### 4. Docker and docker-compose

**No installation needed!** GitHub Actions runners (ubuntu-latest) come with Docker and docker-compose pre-installed:
- Docker Engine 20.10+
- docker-compose v2.x

The workflow includes a verification step to confirm availability.

## Benefits of AWS Approach

### Single Source of Truth
- ✅ Same secret used in CI and production
- ✅ No secret duplication
- ✅ Consistent with ESO configuration
- ✅ Independent from platform repo

### Security
- ✅ OIDC authentication (no long-lived credentials)
- ✅ Secrets masked in GitHub logs
- ✅ IAM policies control access
- ✅ Audit trail in CloudTrail

### Maintenance
- ✅ Update secret once in AWS
- ✅ Automatically available in CI and K8s
- ✅ No manual sync needed

### Dependencies
The workflow assumes:
- Poetry is used for dependency management
- `pyproject.toml` exists in `services/agent_executor/`
- Migration files exist in `services/agent_executor/migrations/`

## Advantages

### 1. Script Hierarchy Compliance
- **Clear Separation**: Tier 1 (pipeline) → Tier 2 (orchestration) → Tier 3 (execution)
- **Reusability**: Tier 2 and Tier 3 scripts can be used locally or in other CI systems
- **Maintainability**: Changes to test logic only require updating Tier 3 scripts
- **Ownership**: DevOps owns Tier 1 & 2, Backend Developers own Tier 3

### 2. Automated Testing
- Tests run automatically on every commit
- Catches issues before merging to main
- No manual test execution needed

### 3. Consistent Environment
- Same test infrastructure every time
- No "works on my machine" issues
- Matches local docker-compose setup

### 4. Fast Feedback
- Results appear directly in PR
- Coverage reports available as artifacts
- Test summary in GitHub UI

### 5. Cost Effective
- Uses GitHub-hosted runners (free for public repos)
- Service containers are efficient
- Only runs when relevant code changes

## Comparison with Local Testing

| Aspect | Local (docker-compose) | GitHub Actions |
|--------|------------------------|----------------|
| Setup Time | ~30 seconds | ~2 minutes (first run) |
| Consistency | Varies by machine | Always same |
| Cost | Free | Free (public repos) |
| Automation | Manual | Automatic |
| Results | Terminal only | PR comments + artifacts |
| Coverage | Local HTML | Downloadable artifacts |

## Potential Issues & Solutions

### Issue 1: NATS JetStream Not Starting
**Solution**: Added `NATS_ARGS: "-js"` environment variable to enable JetStream

### Issue 2: Service Health Checks
**Solution**: All services have health checks with retries to ensure readiness

### Issue 3: Test Timeouts
**Solution**: Set 300-second timeout per test (sufficient for LLM API calls)

### Issue 4: Flaky Tests
**Solution**: 
- Use `--tb=short` for concise error output
- Upload full test results as artifacts for debugging
- Can add retry logic if needed

## Alternative Approaches Considered

### Approach 1: Docker Compose in GitHub Actions
**Pros**: Exact match with local setup
**Cons**: Slower, more complex, harder to debug
**Decision**: Not chosen - service containers are simpler

### Approach 2: Self-Hosted Runner
**Pros**: More control, potentially faster
**Cons**: Requires infrastructure, maintenance overhead
**Decision**: Not needed yet - GitHub-hosted sufficient

### Approach 3: Skip LLM API Calls
**Pros**: Faster, no API key needed
**Cons**: Not true integration test
**Decision**: Not chosen - we want real end-to-end validation

## Recommendations

### For Initial Testing
1. Start with manual workflow trigger (`workflow_dispatch`)
2. Run a few times to validate
3. Check test results and coverage
4. Enable automatic triggers once stable

### For Production Use
1. Add branch protection rules requiring tests to pass
2. Set up Slack/email notifications for failures
3. Monitor test execution time
4. Add caching for faster runs

### For Future Enhancements
1. Add unit tests to the workflow
2. Separate unit and integration test jobs
3. Add performance benchmarking
4. Integrate with code quality tools (SonarQube, etc.)

## Testing the Workflow

### Step 1: Add GitHub Secret
```bash
# In GitHub UI:
Settings → Secrets → Actions → New repository secret
Name: OPENAI_API_KEY
Value: sk-...
```

### Step 2: Commit and Push
```bash
git add .github/workflows/agent-executor-integration-tests.yml
git commit -m "feat: Add GitHub Actions workflow for integration tests"
git push origin main
```

### Step 3: Monitor Execution
1. Go to `Actions` tab in GitHub
2. Click on the workflow run
3. Watch the logs in real-time
4. Check test results and artifacts

### Step 4: Verify Results
- ✅ All services start successfully
- ✅ Migrations apply without errors
- ✅ Tests pass (or fail with clear errors)
- ✅ Artifacts are uploaded
- ✅ Coverage report is generated

## Expected Outcomes

### Success Scenario
```
✅ PostgreSQL: Running on port 15433
✅ Dragonfly: Running on port 16380
✅ NATS: Running on port 14222
✅ Migrations: Applied successfully
✅ Tests: 3 passed in 45.2s
✅ Coverage: 85%
```

### Failure Scenario (Example)
```
✅ PostgreSQL: Running on port 15433
✅ Dragonfly: Running on port 16380
✅ NATS: Running on port 14222
✅ Migrations: Applied successfully
❌ Tests: 1 passed, 1 failed in 32.1s
   - test_cloudevent_processing_end_to_end_success: PASSED
   - test_nats_consumer_processing: FAILED (timeout)
```

## Next Steps

1. **Review this proposal** - Confirm approach is acceptable
2. **Add GitHub secret** - OPENAI_API_KEY
3. **Commit workflow file** - Push to repository
4. **Monitor first run** - Check for any issues
5. **Iterate if needed** - Adjust based on results

## Questions to Consider

1. **API Key Usage**: Are you comfortable using OpenAI API in CI? (costs ~$0.01 per test run)
2. **Test Frequency**: Should we limit to main branch only to save API calls?
3. **Notifications**: Do you want Slack/email notifications for failures?
4. **Branch Protection**: Should we require tests to pass before merging?

## Conclusion

This GitHub Actions workflow provides automated, consistent integration testing for the agent_executor service. It matches the local docker-compose setup while providing better automation and feedback. The workflow is ready to use once the OPENAI_API_KEY secret is added.

**Status**: ✅ Ready for implementation
**Risk Level**: Low
**Estimated Setup Time**: 10 minutes
**Estimated Run Time**: 3-5 minutes per execution
