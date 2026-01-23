#!/bin/bash
# Elasticsearch Setup Script for Competitor Benchmarks (BENCH-05)
#
# Creates the geo_events index with geo_point mapping for fair comparison
# with ArcherDB geospatial operations.
#
# Usage: ./setup-elasticsearch.sh [--default]
#   --default: Use default configuration instance (port 9201)

set -euo pipefail

# Configuration
ES_HOST="${ES_HOST:-localhost}"
ES_PORT="${ES_PORT:-9200}"

# Parse arguments
USE_DEFAULT=false
for arg in "$@"; do
    case $arg in
        --default)
            USE_DEFAULT=true
            ES_PORT=9201
            shift
            ;;
    esac
done

ES_URL="http://$ES_HOST:$ES_PORT"

echo "Setting up Elasticsearch for benchmarks..."
echo "  URL: $ES_URL"
echo "  Configuration: $([ "$USE_DEFAULT" = true ] && echo "default" || echo "tuned")"

# Wait for Elasticsearch to be ready
echo "Waiting for Elasticsearch to be ready..."
for i in {1..60}; do
    if curl -s "$ES_URL/_cluster/health" 2>/dev/null | grep -q '"status"'; then
        echo "Elasticsearch is ready."
        break
    fi
    echo "Waiting... ($i/60)"
    sleep 5
done

# Check cluster health
echo ""
echo "Cluster health:"
curl -s "$ES_URL/_cluster/health?pretty"

# Delete existing index if any
echo ""
echo "Removing existing geo_events index..."
curl -s -X DELETE "$ES_URL/geo_events" 2>/dev/null || true

# Create index with geo_point mapping
echo ""
echo "Creating geo_events index with geo_point mapping..."
curl -s -X PUT "$ES_URL/geo_events" -H 'Content-Type: application/json' -d '{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0,
    "refresh_interval": "1s",
    "index": {
      "sort.field": "timestamp_ns",
      "sort.order": "desc"
    }
  },
  "mappings": {
    "properties": {
      "entity_id": {
        "type": "keyword"
      },
      "timestamp_ns": {
        "type": "long"
      },
      "location": {
        "type": "geo_point"
      },
      "altitude_mm": {
        "type": "integer"
      },
      "heading_centideg": {
        "type": "integer"
      },
      "speed_mm_s": {
        "type": "integer"
      },
      "accuracy_mm": {
        "type": "integer"
      },
      "content": {
        "type": "binary"
      }
    }
  }
}'

echo ""
echo ""

# Verify index creation
echo "Verifying index creation..."
curl -s "$ES_URL/geo_events/_mapping?pretty"

echo ""
echo "Elasticsearch setup complete."
echo ""
echo "Index configuration:"
echo "  - Type: geo_point for location"
echo "  - Sorting: timestamp_ns descending"
echo "  - Shards: 1 (single node)"
echo "  - Replicas: 0 (benchmark mode)"
