# Service Development and Testing Guide - deepagents-runtime

## Date: 2024-12-25
## Context: Complete Service Developer Guide for Platform-Based CI/CD and Testing

> **Platform Reference**: See `zerotouch-platform/llm-context/CI-WORKFLOW-GUIDE.md` and `zerotouch-platform/llm-context/in-cluster-test.md` for configuration details and platform workflow.

---

## Why Platform-Based CI?

### **Focus on Business Logic, Not Infrastructure**
- **Problem**: Services spent 60% of development time on CI infrastructure
- **Solution**: Platform owns CI, services own business logic
- **Result**: 10x faster service development, consistent quality

### **Production Parity Eliminates Surprises**
- **Problem**: "Works on my machine" and "works in CI, fails in production"
- **Solution**: CI runs in identical infrastructure to production
- **Result**: If CI passes, production deployment will work

### **Real Dependencies Catch Real Issues**
- **Problem**: Mock drift - mocks don't match real service behavior
- **Solution**: Test against actual PostgreSQL, Redis, NATS, etc.
- **Result**: Integration issues caught in CI, not production

---

## Why In-Cluster Testing?

### **Production Parity**
- ✅ **Real Infrastructure**: Tests run against actual PostgreSQL, Redis, NATS (not mocks)
- ✅ **Real Networking**: In-cluster DNS, service discovery, network policies
- ✅ **Real Security**: RBAC, secrets injection, service accounts
- ✅ **Real Performance**: Resource limits, scaling behavior, actual latency

### **Reliability Benefits**
- ✅ **Eliminates Environment Drift**: CI environment identical to production
- ✅ **Catches Integration Issues**: Real service-to-service communication
- ✅ **Validates Deployment**: GitOps patterns, Kubernetes manifests
- ✅ **Tests Failure Scenarios**: Network partitions, resource constraints

### **Developer Benefits**
- ✅ **High Confidence**: If tests pass, production deployment will work
- ✅ **Faster Debugging**: Issues caught in CI, not production
- ✅ **Consistent Results**: Same infrastructure every time
- ✅ **Zero CI Maintenance**: Platform team handles all infrastructure updates

---

## How Service CI Works

### **Service Entry Point**
Create `scripts/ci/in-cluster-test.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Clone platform if not already present
if [[ ! -d "zerotouch-platform" ]]; then
    git clone https://github.com/arun4infra/zerotouch-platform.git
fi

# Platform handles everything based on ci/config.yaml
./zerotouch-platform/scripts/bootstrap/preview/tenants/in-cluster-test.sh
```

### **GitHub Integration**
```yaml
jobs:
  integration-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Service CI
        run: ./scripts/ci/in-cluster-test.sh
```

### **Configuration Contract**
- Create `ci/config.yaml` declaring your service needs
- See `zerotouch-platform/llm-context/in-cluster-test.md` for configuration schema
- Platform discovers everything from this file

---

## How Local Development Works

### **Quick Local Testing (Recommended)**
```bash
# Service provides standardized entry point
./scripts/ci/in-cluster-test.sh
```

**Why this works:**
- Creates real Kubernetes cluster locally
- Deploys your service with real dependencies
- Runs tests in production-like environment
- Eliminates "works locally, fails in CI" issues

### **Service-Only Development**
For rapid iteration during development:
```bash
# Use docker-compose for local dependencies
docker-compose up -d postgres redis nats

# Set environment variables for development
export USE_MOCK_LLM=true
python -m uvicorn api.main:app --reload --host 0.0.0.0 --port 8000
```

**Why this approach:**
- Faster iteration cycles during development
- No cluster overhead for simple changes
- Still uses real dependencies (not mocks)

---

## How to Test Your Service

### **Focus on Business Logic**
```python
class TestDeepAgentsRuntime:
    @pytest.fixture(autouse=True)
    def setup_llm_mocking(self, monkeypatch):
        """Platform provides USE_MOCK_LLM=true in CI"""
        assert os.getenv("USE_MOCK_LLM") == "true"
        
    async def test_agent_execution_workflow(self):
        """Test your service's main business logic"""
        # Platform provides all infrastructure
        # Focus on testing your API endpoints and business logic
        pass
```

**Why this pattern:**
- Tests your actual business logic
- Platform provides all infrastructure dependencies
- Focus on API behavior, not infrastructure setup

### **Test API Integration**
```python
from fastapi.testclient import TestClient
from api.main import app

def test_api_endpoints():
    """Test your service's HTTP/WebSocket APIs"""
    with TestClient(app) as client:
        response = client.post("/deepagents-runtime/invoke", json=request_data)
        assert response.status_code == 200
        # Platform ensures your service has access to all dependencies
```

### **Test Dependency Integration**
```python
def test_service_integration():
    """Test service integration with platform-provided dependencies"""
    # Platform provides: POSTGRES_*, DRAGONFLY_*, NATS_URL
    # Your service reads these from environment
    # Test your service's integration with these dependencies
    pass
```

**Why integration testing matters:**
- Catches issues between your service and dependencies
- Validates your service's environment variable usage
- Tests real database/cache/messaging behavior

---

## How Service Requirements Work

### **Health Endpoints (Platform Contract)**
Your service must implement standard health endpoints:
- `/health` - Liveness probe
- `/ready` - Readiness probe with dependency checks

**Why health endpoints matter:**
- Platform uses these for deployment validation
- Kubernetes uses these for pod lifecycle management
- Enables automatic failure detection and recovery

### **Environment Integration (Platform Contract)**
Your service reads platform-provided configuration from environment variables.
Platform automatically provides connection details based on your declared dependencies.

**Why environment variables:**
- Platform automatically provides connection details
- No hardcoded credentials or connection strings
- Same pattern works in development, CI, and production

### **Container Contract**
Your Dockerfile should provide `scripts/ci/run.sh` for service execution.

---

## How Debugging Works

### **Service Issues (Your Responsibility)**
- Business logic bugs
- API endpoint problems
- Service-specific configuration errors
- Health endpoint implementation

### **Platform Issues (Platform Team Responsibility)**
- Infrastructure setup failures
- Dependency deployment issues
- Platform service problems
- Resource optimization

### **Debugging Approach**
```bash
# Use your service's CI script
./scripts/ci/in-cluster-test.sh

# Check service-specific logs
kubectl logs -n intelligence-deepagents -l app=deepagents-runtime
```

**Common Service Issues:**
- Service doesn't read environment variables correctly
- Health endpoints not implemented properly
- Dependencies not declared in `ci/config.yaml`

## Best Practices

### **DO**
- ✅ Focus tests on business logic and API behavior
- ✅ Use platform-provided infrastructure in tests
- ✅ Read configuration from environment variables
- ✅ Implement proper health endpoints
- ✅ Mock expensive external APIs (LLMs) in CI

**Why these practices:**
- Faster test execution
- More reliable results
- Easier debugging
- Better production parity

### **DON'T**
- ❌ Create custom CI infrastructure scripts
- ❌ Mock platform-provided dependencies
- ❌ Hardcode connection strings or credentials
- ❌ Test infrastructure setup (platform's responsibility)

**Why avoid these:**
- Creates maintenance burden
- Introduces mock drift
- Reduces production parity
- Duplicates platform functionality

---

## Key Benefits for Service Developers

### **What You Get**
- 🚀 **10x Faster Development**: Focus on business logic, not CI infrastructure
- 🔒 **Production Confidence**: Tests run in identical infrastructure to production
- 🛠️ **Zero Maintenance**: Platform team handles all CI infrastructure updates
- 📊 **Better Reliability**: Consistent, battle-tested CI patterns
- 💰 **Cost Effective**: Optimized resource usage and smart API mocking

### **What You Focus On**
- 🎯 **Business Logic**: Your service's core functionality
- 🎯 **API Design**: HTTP/WebSocket endpoint behavior
- 🎯 **Integration Logic**: How your service uses dependencies
- 🎯 **Error Handling**: Service-specific error scenarios
- 🎯 **Performance**: Service-level performance characteristics

---

## Development Workflow Examples

### **Daily Development Cycle**
```bash
# 1. Make code changes
# 2. Test locally with real dependencies
./scripts/ci/in-cluster-test.sh

# 3. Push changes - CI runs automatically
git push origin feature-branch

# 4. CI validates with same infrastructure as production
```

### **Debugging Failed Tests**
```bash
# 1. Run locally to reproduce
./scripts/ci/in-cluster-test.sh

# 2. Check service logs
kubectl logs -n intelligence-deepagents -l app=deepagents-runtime

# 3. Check service configuration
cat ci/config.yaml

# 4. Focus on service-specific issues, not infrastructure
```

### **Adding New Dependencies**
```bash
# 1. Update ci/config.yaml with new dependency
# 2. Update service code to use new dependency
# 3. Test locally
./scripts/ci/in-cluster-test.sh

# 4. Platform automatically provides new dependency in CI
```

**Why this workflow works:**
- Same testing approach for local and CI
- Platform handles all infrastructure complexity
- Service developers focus on business logic
- Consistent results across environments