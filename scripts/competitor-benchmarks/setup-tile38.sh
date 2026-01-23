#!/bin/bash
# Tile38 Setup Script for Competitor Benchmarks (BENCH-04)
#
# Verifies Tile38 connection and prepares for benchmarking.
# Tile38 is schema-less, so no table creation is needed.
#
# Usage: ./setup-tile38.sh

set -euo pipefail

# Configuration
TILE38_HOST="${TILE38_HOST:-localhost}"
TILE38_PORT="${TILE38_PORT:-9851}"

echo "Setting up Tile38 for benchmarks..."
echo "  Host: $TILE38_HOST:$TILE38_PORT"

# Wait for Tile38 to be ready
echo "Waiting for Tile38 to be ready..."
for i in {1..30}; do
    if tile38-cli -h "$TILE38_HOST" -p "$TILE38_PORT" PING 2>/dev/null | grep -q "PONG"; then
        echo "Tile38 is ready."
        break
    fi
    # Fallback to redis-cli if tile38-cli not available
    if redis-cli -h "$TILE38_HOST" -p "$TILE38_PORT" PING 2>/dev/null | grep -q "PONG"; then
        echo "Tile38 is ready (via redis-cli)."
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# Clear any existing benchmark data
echo "Clearing existing benchmark data..."
if command -v tile38-cli &> /dev/null; then
    tile38-cli -h "$TILE38_HOST" -p "$TILE38_PORT" DROP geobench 2>/dev/null || true
else
    redis-cli -h "$TILE38_HOST" -p "$TILE38_PORT" DROP geobench 2>/dev/null || true
fi

# Verify server info
echo ""
echo "Tile38 server information:"
if command -v tile38-cli &> /dev/null; then
    tile38-cli -h "$TILE38_HOST" -p "$TILE38_PORT" SERVER
else
    redis-cli -h "$TILE38_HOST" -p "$TILE38_PORT" SERVER
fi

echo ""
echo "Tile38 setup complete."
echo ""
echo "Notes:"
echo "  - Tile38 is schema-less; data keys will be created during benchmark"
echo "  - Collection name: geobench"
echo "  - Entity format: SET geobench <entity_id> POINT <lat> <lon>"
