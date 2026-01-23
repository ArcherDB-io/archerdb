#!/bin/bash
# PostGIS Setup Script for Competitor Benchmarks (BENCH-03)
#
# Creates the geo_events table with GIST spatial index for fair comparison
# with ArcherDB geospatial operations.
#
# Usage: ./setup-postgis.sh [--default]
#   --default: Use default configuration instance (port 5433)

set -euo pipefail

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-bench}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-bench}"
POSTGRES_DB="${POSTGRES_DB:-geobench}"

# Parse arguments
USE_DEFAULT=false
for arg in "$@"; do
    case $arg in
        --default)
            USE_DEFAULT=true
            POSTGRES_PORT=5433
            shift
            ;;
    esac
done

echo "Setting up PostGIS for benchmarks..."
echo "  Host: $POSTGRES_HOST:$POSTGRES_PORT"
echo "  Database: $POSTGRES_DB"
echo "  Configuration: $([ "$USE_DEFAULT" = true ] && echo "default" || echo "tuned")"

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" >/dev/null 2>&1; then
        echo "PostgreSQL is ready."
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# Create schema
echo "Creating geo_events table..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'EOF'
-- Enable PostGIS extension
CREATE EXTENSION IF NOT EXISTS postgis;

-- Drop existing table if any
DROP TABLE IF EXISTS geo_events;

-- Create geo_events table matching ArcherDB schema
-- Using geography type for accurate distance calculations
CREATE TABLE geo_events (
    id SERIAL PRIMARY KEY,
    entity_id UUID NOT NULL,
    timestamp_ns BIGINT NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    altitude_mm INTEGER DEFAULT 0,
    heading_centideg INTEGER DEFAULT 0,
    speed_mm_s INTEGER DEFAULT 0,
    accuracy_mm INTEGER DEFAULT 1000,
    content BYTEA,
    location GEOGRAPHY(POINT, 4326) GENERATED ALWAYS AS (
        ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
    ) STORED
);

-- Create spatial index using GIST for efficient queries
CREATE INDEX idx_geo_events_location ON geo_events USING GIST (location);

-- Create index on entity_id for UUID lookups
CREATE INDEX idx_geo_events_entity ON geo_events (entity_id);

-- Create index on timestamp for time-based queries
CREATE INDEX idx_geo_events_timestamp ON geo_events (timestamp_ns DESC);

-- Analyze for query planner
ANALYZE geo_events;

-- Verify setup
SELECT
    'PostGIS version: ' || PostGIS_Version() AS info
UNION ALL
SELECT
    'Table created: geo_events with GIST index';
EOF

echo "PostGIS setup complete."
echo ""
echo "Table schema:"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\d geo_events"
