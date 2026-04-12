#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
# Aerospike Setup Script for Competitor Benchmarks (BENCH-06)
#
# Verifies Aerospike namespace is ready and creates secondary index
# for geospatial queries.
#
# Usage: ./setup-aerospike.sh

set -euo pipefail

# Configuration
AEROSPIKE_HOST="${AEROSPIKE_HOST:-localhost}"
AEROSPIKE_PORT="${AEROSPIKE_PORT:-3000}"
AEROSPIKE_NAMESPACE="${AEROSPIKE_NAMESPACE:-geobench}"

echo "Setting up Aerospike for benchmarks..."
echo "  Host: $AEROSPIKE_HOST:$AEROSPIKE_PORT"
echo "  Namespace: $AEROSPIKE_NAMESPACE"

# Wait for Aerospike to be ready
echo "Waiting for Aerospike to be ready..."
for i in {1..30}; do
    if asinfo -h "$AEROSPIKE_HOST" -p "$AEROSPIKE_PORT" -v "status" 2>/dev/null | grep -q "ok"; then
        echo "Aerospike is ready."
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# Verify namespace exists
echo ""
echo "Checking namespace configuration..."
asinfo -h "$AEROSPIKE_HOST" -p "$AEROSPIKE_PORT" -v "namespace/$AEROSPIKE_NAMESPACE"

# Clear existing data (truncate namespace)
echo ""
echo "Clearing existing benchmark data..."
aql -h "$AEROSPIKE_HOST" -p "$AEROSPIKE_PORT" -c "TRUNCATE $AEROSPIKE_NAMESPACE" 2>/dev/null || true

# Create geospatial index
echo ""
echo "Creating geospatial secondary index..."
aql -h "$AEROSPIKE_HOST" -p "$AEROSPIKE_PORT" <<EOF
-- Drop existing index if any
DROP INDEX $AEROSPIKE_NAMESPACE geo_events_location_idx;

-- Create geospatial index on location bin
CREATE INDEX geo_events_location_idx ON $AEROSPIKE_NAMESPACE.geo_events (location) GEO2DSPHERE;

-- Create index on entity_id for lookups
CREATE INDEX geo_events_entity_idx ON $AEROSPIKE_NAMESPACE.geo_events (entity_id) STRING;
EOF

# Verify setup
echo ""
echo "Aerospike setup complete."
echo ""
echo "Index configuration:"
aql -h "$AEROSPIKE_HOST" -p "$AEROSPIKE_PORT" -c "SHOW INDEXES $AEROSPIKE_NAMESPACE"

echo ""
echo "Notes:"
echo "  - Namespace: $AEROSPIKE_NAMESPACE"
echo "  - Set: geo_events"
echo "  - Geospatial index: geo_events_location_idx (GEO2DSPHERE)"
echo "  - Entity index: geo_events_entity_idx (STRING)"
