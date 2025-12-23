# Production Deployment Guide

This document outlines the production deployment process for deepagents-runtime using the tenant registry pattern.

## Architecture Overview

```
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│  deepagents-runtime │    │  zerotouch-tenants  │    │  zerotouch-platform │
│     (This Repo)     │────▶│   (Tenant Registry) │────▶│   (Platform Core)   │
│                     │    │                     │    │                     │
│ • Source Code       │    │ • Tenant Config     │    │ • ApplicationSet    │
│ • Docker Image      │    │ • Repository Creds  │    │ • ArgoCD            │
│ • Platform Claims   │    │                     │    │ • Infrastructure    │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
```

## Deployment Flow

### 1. **Code Changes** (This Repository)
```bash
# Developer workflow
git checkout -b feature/new-feature
# Make changes...
git commit -m "Add new feature"
git push origin feature/new-feature
# Create PR → Merge to main
```

### 2. **Automated Image Build** (GitHub Actions)
```yaml
# Triggered on push to main
main branch → Build Docker Image → Push to ghcr.io/arun4infra/deepagents-runtime → Update deployment manifest
```

### 3. **GitOps Deployment** (ArgoCD)
```yaml
# Automatic via tenant registry
Manifest Change → ArgoCD Detects → Sync Application → Deploy to Production
```

## Production Workflows

### **Build and Push Workflow** (`.github/workflows/build-and-push.yml`)

**Triggers:**
- Push to `main` branch
- Git tags (`v*`)
- Manual workflow dispatch

**Actions:**
1. Build Docker image with multi-platform support
2. Push to GitHub Container Registry (`ghcr.io/arun4infra/deepagents-runtime`)
3. Update deployment manifest with new image tag
4. Commit and push manifest change (triggers ArgoCD sync)

**Image Tagging Strategy:**
- `main-{sha}` - Main branch builds
- `v1.2.3` - Semantic version tags
- `latest` - Latest stable release

### **Integration Tests Workflow** (`.github/workflows/deepagnets-integration-tests.yml`)

**Triggers:**
- Pull requests to `main`
- Push to `main` branch
- Daily scheduled runs (2 AM UTC)

**Actions:**
1. Bootstrap preview environment (Kind cluster)
2. Build and deploy service
3. Run comprehensive integration tests
4. Generate test reports and artifacts

## Production Infrastructure

### **Database Migrations**

**Strategy:** Kubernetes Job (one-time execution)
```yaml
# migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: deepagents-runtime-migrations
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Runs before deployment
```

**Features:**
- ✅ Migration locking (prevents concurrent runs)
- ✅ Automatic rollback on failure
- ✅ 10-minute timeout protection
- ✅ Runs before application deployment

### **Health Checks**

**Liveness Probe:** `/health`
- Simple service availability check
- 30s initial delay, 10s interval
- Restarts pod if failing

**Readiness Probe:** `/ready`
- Comprehensive dependency check (PostgreSQL, Dragonfly, NATS)
- 10s initial delay, 5s interval
- Removes from load balancer if failing

### **Secrets Management**

**AWS SSM Parameter Store:**
```bash
# Repository credentials
/zerotouch/prod/argocd/repos/deepagents-runtime/url
/zerotouch/prod/argocd/repos/deepagents-runtime/username
/zerotouch/prod/argocd/repos/deepagents-runtime/password

# Application secrets
/zerotouch/prod/intelligence-deepagents/llm-keys/openai-api-key
/zerotouch/prod/intelligence-deepagents/llm-keys/anthropic-api-key
```

**ExternalSecrets Operator:**
- Syncs secrets from SSM to Kubernetes
- Automatic rotation when SSM parameters change
- Encrypted at rest and in transit

## Deployment Process

### **Initial Setup** (One-time)

1. **Add secrets to AWS SSM:**
   ```bash
   # In zerotouch-platform repo
   echo "/zerotouch/prod/argocd/repos/deepagents-runtime/url=https://github.com/arun4infra/deepagents-runtime.git" >> .env.ssm
   echo "/zerotouch/prod/argocd/repos/deepagents-runtime/username=your-github-username" >> .env.ssm
   echo "/zerotouch/prod/argocd/repos/deepagents-runtime/password=ghp_your_token" >> .env.ssm
   echo "/zerotouch/prod/intelligence-deepagents/llm-keys/openai-api-key=sk-your-key" >> .env.ssm
   echo "/zerotouch/prod/intelligence-deepagents/llm-keys/anthropic-api-key=sk-ant-your-key" >> .env.ssm
   
   ./scripts/bootstrap/08-inject-ssm-parameters.sh
   ```

2. **Tenant registry is already configured:**
   - Repository credentials: `zerotouch-tenants/repositories/deepagents-runtime-repo.yaml`
   - Tenant configuration: `zerotouch-tenants/tenants/deepagents-runtime/config.yaml`

### **Regular Deployments**

1. **Merge PR to main:**
   ```bash
   git checkout main
   git pull origin main
   # GitHub Actions automatically builds and pushes image
   ```

2. **Monitor deployment:**
   ```bash
   # Check ArgoCD application
   kubectl get application deepagents-runtime -n argocd
   
   # Watch deployment progress
   kubectl get pods -n intelligence-deepagents -w
   
   # Check application health
   kubectl get application deepagents-runtime -n argocd -o yaml
   ```

### **Rollback Process**

1. **Revert image tag in deployment manifest:**
   ```bash
   # Edit platform/claims/intelligence-deepagents/agent-executor-deployment.yaml
   # Change image tag to previous version
   git commit -m "Rollback to previous version"
   git push origin main
   ```

2. **ArgoCD will automatically sync the rollback**

## Monitoring and Troubleshooting

### **Application Status**
```bash
# Check ArgoCD application
kubectl get application deepagents-runtime -n argocd

# Check deployment status
kubectl get deployment deepagents-runtime -n intelligence-deepagents

# Check pod health
kubectl get pods -n intelligence-deepagents
kubectl describe pod <pod-name> -n intelligence-deepagents
```

### **Logs**
```bash
# Application logs
kubectl logs -n intelligence-deepagents -l app.kubernetes.io/name=deepagents-runtime

# Migration job logs
kubectl logs -n intelligence-deepagents job/agent-executor-migrations

# ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

### **Health Checks**
```bash
# Port forward to test health endpoints
kubectl port-forward -n intelligence-deepagents svc/deepagents-runtime 8080:8080

# Test endpoints
curl http://localhost:8080/health
curl http://localhost:8080/ready
```

### **Common Issues**

**1. Image Pull Errors:**
- Check GitHub Container Registry credentials
- Verify image exists: `docker pull ghcr.io/arun4infra/deepagents-runtime:latest`

**2. Migration Failures:**
- Check migration job logs: `kubectl logs job/deepagents-runtime-migrations -n intelligence-deepagents`
- Verify database connectivity and credentials

**3. Application Not Ready:**
- Check readiness probe: `curl http://pod-ip:8080/ready`
- Verify external service connectivity (PostgreSQL, Dragonfly, NATS)

**4. ArgoCD Sync Issues:**
- Check application status: `kubectl get application deepagents-runtime -n argocd -o yaml`
- Verify repository credentials: `kubectl get secret repo-deepagents-runtime -n argocd`

## Security Considerations

1. **Container Security:**
   - Non-root user (appuser)
   - Minimal base image (python:3.11-slim)
   - No privileged containers

2. **Network Security:**
   - Service mesh integration ready
   - Network policies can be applied

3. **Secrets Management:**
   - No secrets in Git repositories
   - AWS SSM encryption at rest
   - Kubernetes secrets encryption in etcd

4. **RBAC:**
   - Service account with minimal permissions
   - Namespace isolation

## Performance Tuning

### **Resource Requests/Limits**
```yaml
# Current: size: medium (defined in EventDrivenService)
# Adjust based on load testing results
```

### **Scaling**
```yaml
# Horizontal Pod Autoscaler can be added
# KEDA integration for event-driven scaling
```

### **Database Connection Pooling**
```python
# Already configured in psycopg connection pool
# Tune pool size based on load
```

## Disaster Recovery

### **Backup Strategy**
- Database: CNPG automatic backups
- Configuration: Git repositories (immutable)
- Secrets: AWS SSM (encrypted, versioned)

### **Recovery Process**
1. Restore database from CNPG backup
2. Redeploy from Git (ArgoCD sync)
3. Verify application health

## Support and Maintenance

### **Regular Tasks**
- Monitor application metrics
- Review and rotate secrets quarterly
- Update dependencies monthly
- Performance testing quarterly

### **Escalation**
1. Check application logs and health endpoints
2. Verify external service connectivity
3. Review ArgoCD application status
4. Contact platform team for infrastructure issues

---

**Next Steps:**
1. Set up monitoring and alerting
2. Implement load testing
3. Add performance metrics
4. Configure backup verification