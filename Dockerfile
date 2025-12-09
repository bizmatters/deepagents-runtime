# Multi-stage build for agent_executor service
# Runtime image - Minimal production image
FROM python:3.11-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Create non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Install uv for fast dependency management
RUN pip install --no-cache-dir uv

# Copy pyproject.toml for dependency installation
COPY services/agent_executor/pyproject.toml ./pyproject.toml

# Install system dependencies for psycopg v3 and psql client (for migrations)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    libpq-dev \
    postgresql-client \
    gcc \
    && uv pip install --system --no-cache -r pyproject.toml \
    && apt-get purge -y --auto-remove gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy application code
COPY services/agent_executor/api/ ./agent_executor/api/
COPY services/agent_executor/core/ ./agent_executor/core/
COPY services/agent_executor/services/ ./agent_executor/services/
COPY services/agent_executor/models/ ./agent_executor/models/
COPY services/agent_executor/observability/ ./agent_executor/observability/
COPY services/agent_executor/__init__.py ./agent_executor/__init__.py

# Copy migrations directory (required by init container)
COPY services/agent_executor/migrations/ ./migrations/

# Copy Tier 3 scripts (for CI entrypoint)
COPY services/agent_executor/scripts/ ./scripts/

# Set ownership to non-root user
RUN chown -R appuser:appuser /app && \
    chmod +x /app/scripts/ci/*.sh

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8080/health', timeout=5)"

# Start application using Tier 3 CI entrypoint script
ENTRYPOINT ["/app/scripts/ci/run.sh"]
