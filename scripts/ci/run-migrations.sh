#!/bin/bash
set -e

# Tier 3 Script: Run PostgreSQL Migrations for agent-executor
# Owner: Backend Developer
# Called by: Kubernetes init container, CI/CD pipelines
# Purpose: Execute database migrations for agent_executor service

# --- Environment Variables ---
# Required:
#   POSTGRES_HOST      - PostgreSQL host
#   POSTGRES_PORT      - PostgreSQL port (default: 5432)
#   POSTGRES_DB        - Database name
#   POSTGRES_USER      - Database user
#   POSTGRES_PASSWORD  - Database password
#
# Optional:
#   MIGRATION_DIR      - Path to migration files (default: /app/migrations)
#   POSTGRES_SCHEMA    - PostgreSQL schema to use (default: agent_executor)

POSTGRES_HOST="${POSTGRES_HOST}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-langgraph_dev}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
POSTGRES_SCHEMA="${POSTGRES_SCHEMA:-agent_executor}"
MIGRATION_DIR="${MIGRATION_DIR:-/app/migrations}"

# Validate required environment variables
if [ -z "$POSTGRES_HOST" ]; then
  echo "ERROR: POSTGRES_HOST environment variable is required"
  exit 1
fi

if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "ERROR: POSTGRES_PASSWORD environment variable is required"
  exit 1
fi

echo "--- Running PostgreSQL Migrations ---"
echo "Host: $POSTGRES_HOST:$POSTGRES_PORT"
echo "Database: $POSTGRES_DB"
echo "Schema: $POSTGRES_SCHEMA"
echo "Migration Directory: $MIGRATION_DIR"

# Check if psql is available
if ! command -v psql &> /dev/null; then
  echo "ERROR: psql command not found. Ensure PostgreSQL client is installed."
  exit 1
fi

# Test database connectivity
echo "Testing database connectivity..."
export PGPASSWORD="$POSTGRES_PASSWORD"
if ! psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1;" > /dev/null 2>&1; then
  echo "ERROR: Cannot connect to PostgreSQL database"
  echo "Host: $POSTGRES_HOST:$POSTGRES_PORT"
  echo "Database: $POSTGRES_DB"
  echo "User: $POSTGRES_USER"
  exit 1
fi
echo "✅ Database connection successful"

# Create schema if it doesn't exist
echo "Ensuring schema exists: $POSTGRES_SCHEMA"
psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE SCHEMA IF NOT EXISTS ${POSTGRES_SCHEMA};" || {
  echo "ERROR: Failed to create schema"
  exit 1
}

# Run migrations using psql directly
migration_count=0
for migration in "$MIGRATION_DIR"/*.up.sql; do
  if [ ! -f "$migration" ]; then
    echo "WARNING: No migration files found in $MIGRATION_DIR"
    break
  fi

  echo "Applying migration: $(basename "$migration") to schema: $POSTGRES_SCHEMA"

  # Execute migration with psql
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -c "SET search_path TO ${POSTGRES_SCHEMA};" \
    -f "$migration"

  if [ $? -eq 0 ]; then
    echo "✅ Migration applied: $(basename "$migration")"
    migration_count=$((migration_count + 1))
  else
    echo "❌ Migration failed: $(basename "$migration")"
    exit 1
  fi
done

if [ $migration_count -eq 0 ]; then
  echo "WARNING: No migrations were applied"
else
  echo "--- Migrations Complete: $migration_count migration(s) applied ---"
fi

exit 0
