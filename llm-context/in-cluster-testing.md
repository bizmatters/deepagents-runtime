## Testing command
export CLEANUP_CLUSTER=false && export $(grep -v '^#' .env | grep -v '^$' | xargs) && ./scripts/ci/
in-cluster-test.sh

## Cluster commands for debugging
kubectl get pods -n intelligence-deepagents
kubectl logs -n intelligence-deepagents deployment/deepagents-runtime-sandbox --tail=20
kubectl delete pod -n intelligence-deepagents -l app=deepagents-runtime
kubectl get deployment deepagents-runtime-sandbox -n intelligence-deepagents -o yaml | grep -A 10 -B 5 envFrom
kubectl get secrets -n intelligence-deepagents | grep deepagents-runtime

## Check cluster memory usage
docker stats zerotouch-preview-control-plane --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

## AWS SSM Parameter Store
aws ssm put-parameter --name "/zerotouch/prod/deepagents-runtime/postgres_uri" --value "postgresql://neondb_owner:npg_lhaL8SJCzD9v@ep-flat-feather-aekziod9-pooler.c-2.us-east-2.aws.neon.tech/neondb?sslmode=require" --type "SecureString" --overwrite
aws ssm get-parameter --name "/zerotouch/prod/deepagents-runtime/postgres_uri" --with-decryption

## LangGraph CLI Testing
langgraph test --config langgraph.json

## INTEGRATION TESTING
docker build -t deepagents-runtime:ci-test .
kind load docker-image deepagents-runtime:ci-test --name zerotouch-preview

### Use this command when all env.var in-cluster ES already exists

kubectl run integration-test-deepagents --image=deepagents-runtime:ci-test --rm -i --restart=Never -n intelligence-deepagents --overrides='
{
  "spec": {
    "containers": [
      {
        "name": "integration-test-deepagents",
        "image": "deepagents-runtime:ci-test",
        "command": ["python", "-m", "pytest", "tests/integration/", "-v"],
        "envFrom": [
          {"secretRef": {"name": "deepagents-runtime-db-conn", "optional": true}},
          {"secretRef": {"name": "deepagents-runtime-cache-conn", "optional": true}},
          {"secretRef": {"name": "deepagents-runtime-llm-keys", "optional": true}}
        ]
      }
    ]
  }
}'

### Use this command when all env.var in-cluster ES do not exist and you want to pass them as env vars

kubectl run integration-test-deepagents --image=deepagents-runtime:ci-test --rm -i --restart=Never -n intelligence-deepagents --overrides='
{
  "spec": {
    "containers": [
      {
        "name": "integration-test-deepagents",
        "image": "deepagents-runtime:ci-test",
        "command": ["python", "-m", "pytest", "tests/integration/", "-v"],
        "env": [
          {"name": "POSTGRES_URI", "value": "postgresql://neondb_owner:npg_lhaL8SJCzD9v@ep-flat-feather-aekziod9-pooler.c-2.us-east-2.aws.neon.tech/neondb?sslmode=require"},
          {"name": "REDIS_HOST", "value": "redis-10486.crce276.ap-south-1-3.ec2.cloud.redislabs.com"},
          {"name": "REDIS_PORT", "value": "10486"},
          {"name": "REDIS_USERNAME", "value": "pr-user"},
          {"name": "REDIS_PASSWORD", "value": "Password@123"},
          {"name": "OPENAI_API_KEY", "value": "sk-test-key"},
          {"name": "ANTHROPIC_API_KEY", "value": "test-anthropic-key"},
          {"name": "NATS_URL", "value": "nats://nats.intelligence-deepagents.svc.cluster.local:4222"},
          {"name": "USE_MOCK_LLM", "value": "true"},
          {"name": "RUNTIME_MODE", "value": "test"}
        ]
      }
    ]
  }
}'

## Testing in-cluster service
kubectl port-forward -n intelligence-deepagents svc/deepagents-runtime-sandbox-http 8080:8080 &

curl -s http://localhost:8080/health
curl -s http://localhost:8080/ready
curl -s http://localhost:8080/runs -X POST -H "Content-Type: application/json" -d '{"input":{"message":"test"}}'