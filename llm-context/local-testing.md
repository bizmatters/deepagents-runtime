## pass below env variables 
NODE_ENV=local

### Cache connection - External Redis for local testing  
REDIS_HOST=redis-10486.crce276.ap-south-1-3.ec2.cloud.redislabs.com
REDIS_PORT=10486
REDIS_USERNAME=pr-user
REDIS_PASSWORD=Password@123

### PG DG
POSTGRES_URI=postgresql://neondb_owner:npg_r6gZp2VtqwUv@ep-autumn-field-ah1ydtm3-pooler.c-3.us-east-1.aws.neon.tech/neondb?sslmode=require

# Cache Configuration (will be overridden by platform)
REDIS_HOST=redis-10486.crce276.ap-south-1-3.ec2.cloud.redislabs.com
REDIS_PORT=10486
REDIS_USERNAME=pr-user
REDIS_PASSWORD=Password@123
NATS_URL=nats://localhost:14222
USE_MOCK_LLM=true
MODEL=gpt-4.1-mini
RUNTIME_MODE=development
LANGSMITH_TRACING=false


### run below command to run integration test
npm run test:integration -- tests/integration --reporter=verbose
