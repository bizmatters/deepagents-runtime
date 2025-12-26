#!/bin/bash

# Quick script to run CHECKPOINT 1 test in-cluster
# This avoids all port-forwarding issues and tests in the proper environment

set -e

echo "🚀 Running CHECKPOINT 1 test in-cluster..."
echo ""

# Configuration
NAMESPACE="intelligence-deepagents"
TEST_PATH="tests/integration/test_nats_events_integration.py::TestNATSEventsIntegration::test_full_workflow_integration"
JOB_NAME="checkpoint1-test-$(date +%s)"
IMAGE_TAG="ci-test"

echo "📋 Configuration:"
echo "  Namespace: $NAMESPACE"
echo "  Test Path: $TEST_PATH"
echo "  Job Name: $JOB_NAME"
echo ""

# Check if we're in the right directory
if [ ! -f "Dockerfile" ] || [ ! -d "tests/integration" ]; then
    echo "❌ Please run this script from the deepagents-runtime directory"
    exit 1
fi

# Check if kubectl is available and cluster is accessible
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "❌ kubectl is not available or cluster is not accessible"
    echo "Please ensure you have kubectl configured and the cluster is running"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "❌ Namespace '$NAMESPACE' does not exist"
    echo "Please ensure the deepagents-runtime service is deployed"
    exit 1
fi

# Check if required secrets exist
echo "🔍 Checking required secrets..."
for secret in "deepagents-runtime-db-conn" "deepagents-runtime-cache-conn"; do
    if ! kubectl get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "❌ Secret '$secret' not found in namespace '$NAMESPACE'"
        exit 1
    else
        echo "  ✅ $secret"
    fi
done

# Build and load image into cluster (assuming kind cluster)
echo ""
echo "🔨 Building Docker image..."
docker build -t "deepagents-runtime:$IMAGE_TAG" .

echo ""
echo "📦 Loading image into cluster..."
if command -v kind >/dev/null 2>&1; then
    # Try to load into kind cluster
    kind load docker-image "deepagents-runtime:$IMAGE_TAG" --name zerotouch-preview 2>/dev/null || \
    kind load docker-image "deepagents-runtime:$IMAGE_TAG" 2>/dev/null || \
    echo "⚠️  Could not load into kind cluster, assuming image is available"
else
    echo "⚠️  kind not available, assuming image is available in cluster"
fi

# Create test job YAML
echo ""
echo "📝 Creating test job..."
cat > /tmp/checkpoint1-test-job.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: "$JOB_NAME"
  namespace: "$NAMESPACE"
  labels:
    app: deepagents-runtime-tests
    test-type: checkpoint1
spec:
  template:
    metadata:
      labels:
        app: deepagents-runtime-tests
        test-type: checkpoint1
    spec:
      containers:
      - name: test-runner
        image: "deepagents-runtime:$IMAGE_TAG"
        imagePullPolicy: Never
        workingDir: /app
        env:
        # Database credentials from K8s secrets
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-db-conn
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-db-conn
              key: POSTGRES_PASSWORD
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-db-conn
              key: POSTGRES_DB
        - name: DRAGONFLY_PASSWORD
          valueFrom:
            secretKeyRef:
              name: deepagents-runtime-cache-conn
              key: DRAGONFLY_PASSWORD
        # In-cluster service DNS names
        - name: POSTGRES_HOST
          value: "deepagents-runtime-db-rw"
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_SCHEMA
          value: "public"
        - name: DRAGONFLY_HOST
          value: "deepagents-runtime-cache"
        - name: DRAGONFLY_PORT
          value: "6379"
        - name: NATS_URL
          value: "nats://nats.nats.svc:4222"
        # Test configuration
        - name: USE_MOCK_LLM
          value: "true"
        - name: MOCK_TIMEOUT
          value: "60"
        - name: OPENAI_API_KEY
          value: "mock-key-for-testing"
        - name: ANTHROPIC_API_KEY
          value: "mock-key-for-testing"
        command: 
        - "/bin/bash"
        - "-c"
        - |
          set -e
          echo "🚀 CHECKPOINT 1 Test Starting..."
          echo "Test Path: $TEST_PATH"
          echo "Timestamp: \$(date)"
          echo ""
          
          echo "=== Environment Check ==="
          echo "Python: \$(python --version)"
          echo "Working Dir: \$(pwd)"
          echo "Test file exists: \$(test -f '$TEST_PATH' && echo 'YES' || echo 'NO')"
          echo ""
          
          echo "=== Running CHECKPOINT 1 Test ==="
          python -m pytest "$TEST_PATH" -v -s --tb=short --timeout=300
          
          echo ""
          echo "✅ CHECKPOINT 1 Test Complete!"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "250m"
      restartPolicy: Never
      serviceAccountName: default
  backoffLimit: 1
  ttlSecondsAfterFinished: 1800  # Keep for 30 minutes
EOF

# Apply the job
echo "🚀 Starting test job..."
kubectl apply -f /tmp/checkpoint1-test-job.yaml

echo ""
echo "⏳ Waiting for job to complete..."
echo "Job name: $JOB_NAME"
echo ""

# Wait for job completion with progress
TIMEOUT=600  # 10 minutes
ELAPSED=0
POLL_INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check job status
    JOB_STATUS=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
    JOB_FAILED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
    
    if [ "$JOB_STATUS" = "True" ]; then
        echo "✅ Job completed successfully!"
        break
    elif [ "$JOB_FAILED" = "True" ]; then
        echo "❌ Job failed!"
        break
    fi
    
    # Show progress every 30 seconds
    if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        echo "⏳ Still waiting... ($((ELAPSED/60))m $((ELAPSED%60))s elapsed)"
        
        # Show pod status
        POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$POD_NAME" ]; then
            POD_PHASE=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo "   Pod: $POD_NAME ($POD_PHASE)"
        fi
    fi
    
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Get final status and logs
echo ""
echo "=== FINAL RESULTS ==="

POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD_NAME" ]; then
    echo "Pod: $POD_NAME"
    echo ""
    echo "=== TEST LOGS ==="
    kubectl logs "$POD_NAME" -n "$NAMESPACE" 2>/dev/null || echo "Could not retrieve logs"
    echo ""
else
    echo "❌ No pod found for job $JOB_NAME"
fi

# Check final job status
JOB_STATUS=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
JOB_FAILED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")

echo "=== JOB STATUS ==="
echo "Complete: $JOB_STATUS"
echo "Failed: $JOB_FAILED"

if [ "$JOB_STATUS" = "True" ]; then
    echo ""
    echo "🎉 CHECKPOINT 1 VALIDATION PASSED!"
    echo ""
    echo "✅ All API endpoints are working:"
    echo "  - POST /deepagents-runtime/invoke"
    echo "  - WebSocket /deepagents-runtime/stream/{thread_id}"
    echo "  - GET /deepagents-runtime/state/{thread_id}"
    echo ""
    exit 0
elif [ "$JOB_FAILED" = "True" ]; then
    echo ""
    echo "❌ CHECKPOINT 1 VALIDATION FAILED!"
    echo ""
    echo "Check the logs above for details."
    exit 1
else
    echo ""
    echo "⚠️  Job did not complete within timeout"
    exit 1
fi