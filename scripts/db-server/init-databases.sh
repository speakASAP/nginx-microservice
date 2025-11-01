#!/bin/bash
# Initialize databases for projects
# This script runs automatically when PostgreSQL container starts for the first time
# It creates databases based on configuration

set -e

# Wait for PostgreSQL to be ready
until pg_isready -U "$POSTGRES_USER" > /dev/null 2>&1; do
  sleep 1
done

echo "PostgreSQL is ready. Initializing project databases..."

# Create databases for projects defined in environment or config file
# Example: Create database for crypto-ai-agent
if [ -n "$CRYPTO_AI_AGENT_DB_NAME" ]; then
    DB_NAME="$CRYPTO_AI_AGENT_DB_NAME"
    DB_USER="${CRYPTO_AI_AGENT_DB_USER:-crypto}"
    DB_PASSWORD="${CRYPTO_AI_AGENT_DB_PASSWORD:-crypto_pass}"
    
    echo "Creating database: $DB_NAME for user: $DB_USER"
    
    # Create database
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        CREATE DATABASE "$DB_NAME";
        CREATE USER "$DB_USER" WITH ENCRYPTED PASSWORD '$DB_PASSWORD';
        GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$DB_USER";
        ALTER DATABASE "$DB_NAME" OWNER TO "$DB_USER";
EOSQL
    
    echo "Database $DB_NAME created successfully"
fi

# Add more projects here as needed
# Example:
# if [ -n "$PROJECT2_DB_NAME" ]; then
#     ...
# fi

echo "Database initialization complete"

