#!/bin/bash
# Apply the customer management functions to the database

set -e

echo "Applying customer management functions..."

# Use environment variables for database connection
# Required: POSTGRES_HOST, POSTGRES_USER, POSTGRES_DB, POSTGRES_PASSWORD
docker run --rm \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  -v "$(pwd)/09_add_update_customer_functions.sql:/tmp/functions.sql:ro" \
  postgres:15 \
  psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agent_swarm}" -f /tmp/functions.sql

echo "Customer management functions applied successfully!"
