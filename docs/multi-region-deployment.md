# Multi-Region Deployment Guide

This document is currently a design/reference guide, not a GA server deployment path.

The current `archerdb start` CLI does not accept server-side multi-region runtime flags. The examples below describe a proposed future runtime shape and should be treated as architecture and planning material only.

This guide explains the intended ArcherDB multi-region configuration with async replication between a primary region and follower regions.

## Overview

Multi-region deployment provides:
- **Geo-distributed reads**: Low-latency reads from the nearest region
- **Disaster recovery**: Data replicated across regions
- **Read scaling**: Follower regions handle read traffic

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Primary Region (us-east-1)                  │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐                        │
│  │ Replica 0 │  │ Replica 1 │  │ Replica 2 │  ← Writes + Reads      │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘                        │
│        │              │              │                               │
│        └──────────────┼──────────────┘                               │
│                       │                                              │
│                       │ WAL Shipping (async)                         │
│                       ▼                                              │
└─────────────────────────────────────────────────────────────────────┘
                        │
         ┌──────────────┴──────────────┐
         │                             │
         ▼                             ▼
┌─────────────────────┐    ┌─────────────────────┐
│ Follower (eu-west-1)│    │ Follower (ap-south-1)│
│  ┌─────────────┐    │    │  ┌─────────────┐    │
│  │   Replica   │    │    │  │   Replica   │    │
│  └─────────────┘    │    │  └─────────────┘    │
│  Read-only queries  │    │  Read-only queries  │
└─────────────────────┘    └─────────────────────┘
```

## Prerequisites

- ArcherDB binary on all nodes
- Network connectivity between regions (TCP port 3000)
- S3 bucket for cross-region WAL shipping (optional, for high-latency links)

## Deployment Steps

### Step 1: Deploy Primary Region

First, deploy a standard 3-replica cluster in your primary region:

```bash
# Format data files on each node
./archerdb format --cluster=12345 --replica=0 --replica-count=3 /data/archerdb.db  # node 1
./archerdb format --cluster=12345 --replica=1 --replica-count=3 /data/archerdb.db  # node 2
./archerdb format --cluster=12345 --replica=2 --replica-count=3 /data/archerdb.db  # node 3
```

Future runtime sketch for the primary cluster configuration (not accepted by the current `archerdb start` CLI):

```text
# On all primary region nodes
archerdb start \
  --addresses=10.0.1.1:3000,10.0.1.2:3000,10.0.1.3:3000 \
  --region-role=primary \
  --follower-regions=10.0.2.1:3001,10.0.3.1:3001 \
  /data/archerdb.db
```

**Primary Configuration Options (future runtime design):**

| Flag | Description |
|------|-------------|
| `--region-role=primary` | Designates this cluster as the primary region |
| `--follower-regions=<endpoints>` | Comma-separated list of follower endpoints for WAL shipping |

### Step 2: Deploy Follower Regions

Future runtime sketch for each follower region (not accepted by the current `archerdb start` CLI):

```text
# Format the follower data file
archerdb format --cluster=12345 --replica=0 --replica-count=1 /data/archerdb.db

# Start as follower
archerdb start \
  --addresses=10.0.2.1:3001 \
  --region-role=follower \
  --primary-region=10.0.1.1:3000 \
  /data/archerdb.db
```

**Follower Configuration Options (future runtime design):**

| Flag | Description |
|------|-------------|
| `--region-role=follower` | Designates this node as a read-only follower |
| `--primary-region=<endpoint>` | Primary region endpoint for WAL shipping |

### Step 3: Verify Replication

Check replication status on the primary:

```bash
./archerdb repl --cluster=12345 --addresses=10.0.1.1:3000 --command="status"
```

Expected output:
```
Cluster: 12345
Role: primary
Followers:
  - eu-west-1 (10.0.2.1:3001): lag=15ms, ops_behind=3
  - ap-south-1 (10.0.3.1:3001): lag=120ms, ops_behind=25
```

## WAL Shipping Transports

### Direct TCP (Default)

Best for low-latency inter-region links (<100ms RTT):

```text
--region-role=primary \
--follower-regions=10.0.2.1:3001,10.0.3.1:3001
```

### S3 Relay

For high-latency or unreliable links, use S3 as an intermediate buffer:

```text
# Primary
--region-role=primary \
--replication-transport=s3 \
--replication-bucket=my-replication-bucket \
--replication-prefix=prod/wal

# Follower
--region-role=follower \
--primary-region=s3://my-replication-bucket/prod/wal
```

**S3 Configuration:**

| Flag | Description |
|------|-------------|
| `--replication-transport=s3` | Use S3 for WAL shipping |
| `--replication-bucket=<bucket>` | S3 bucket name |
| `--replication-prefix=<prefix>` | S3 key prefix for WAL files |

## Client Configuration

### Routing Writes to Primary

All writes must go to the primary region. SDKs automatically handle this:

```python
import archerdb

# Connect to any region - SDK routes writes to primary
client = archerdb.GeoClientSync(
    cluster_id=12345,
    addresses=["10.0.2.1:3001"]  # Follower address
)

# This write automatically routes to primary
batch = client.create_batch()
batch.insert(archerdb.create_geo_event(...))
batch.submit()  # Routed to primary via follower
```

### Reading from Followers

For low-latency reads, connect directly to the nearest follower:

```python
# Connect to nearest follower for reads
client = archerdb.GeoClientSync(
    cluster_id=12345,
    addresses=["10.0.2.1:3001"],  # EU follower
    prefer_follower_reads=True
)

# Reads served locally from follower
result = client.query_radius(51.5074, -0.1278, 1000)
```

### Staleness Tolerance

Configure maximum acceptable staleness for reads:

```python
from archerdb import OperationOptions

# Allow reads up to 5 seconds behind primary
options = OperationOptions(max_staleness_ms=5000)
result = client.query_radius(lat, lon, radius, options=options)

# Check actual staleness
print(f"Read staleness: {result.staleness_ns / 1e6:.2f}ms")
```

## Monitoring

### Replication Metrics

Monitor these Prometheus metrics:

```
# Replication lag (operations behind)
archerdb_replication_lag_ops{region="eu-west-1"} 15

# Replication lag (time)
archerdb_replication_lag_seconds{region="eu-west-1"} 0.050

# Ship queue depth
archerdb_ship_queue_depth{region="eu-west-1"} 100

# Shipping errors
archerdb_ship_errors_total{region="eu-west-1",error="timeout"} 5
```

### Health Endpoints

Check region health via HTTP:

```bash
# Primary health
curl http://10.0.1.1:8080/health/region

# Response
{
  "role": "primary",
  "followers": [
    {"region": "eu-west-1", "lag_ms": 15, "status": "healthy"},
    {"region": "ap-south-1", "lag_ms": 120, "status": "healthy"}
  ]
}
```

## Failover Procedures

### Planned Failover

For maintenance or region migration:

1. **Stop writes** to primary region
2. **Wait for followers** to catch up (lag → 0)
3. **Promote follower** to primary:
   ```bash
   ./archerdb promote --cluster=12345 --addresses=10.0.2.1:3001
   ```
4. **Reconfigure old primary** as follower
5. **Update client configuration** with new primary

### Unplanned Failover

If primary region fails:

1. **Identify most caught-up follower**:
   ```bash
   ./archerdb status --cluster=12345 --addresses=10.0.2.1:3001
   # Check commit_op to find most advanced follower
   ```

2. **Force promote** the best follower:
   ```bash
   ./archerdb promote --force --cluster=12345 --addresses=10.0.2.1:3001
   ```

   **Warning**: Force promotion may lose operations not yet replicated.

3. **Reconfigure remaining followers** to point to new primary

## Error Handling

### Follower Errors

| Error Code | Name | Description | Action |
|------------|------|-------------|--------|
| 213 | `FOLLOWER_READ_ONLY` | Write attempted on follower | Route to primary |
| 214 | `STALE_FOLLOWER` | Follower too far behind | Wait or use primary |
| 215 | `PRIMARY_UNREACHABLE` | Cannot connect to primary | Check network/failover |
| 216 | `REPLICATION_TIMEOUT` | Replication timeout | Retry or check lag |

### SDK Error Handling

```python
from archerdb import MultiRegionException, MultiRegionError

try:
    batch.submit()
except MultiRegionException as e:
    if e.error == MultiRegionError.FOLLOWER_READ_ONLY:
        # Redirect write to primary
        pass
    elif e.error == MultiRegionError.STALE_FOLLOWER:
        # Data too stale, retry on primary
        pass
```

## Best Practices

1. **Region Selection**: Place primary in the region with most write traffic
2. **Follower Count**: 1-3 followers per region (more increases replication load)
3. **Network**: Use dedicated inter-region links or VPN for replication
4. **Monitoring**: Alert on `replication_lag_seconds > 5`
5. **Backups**: Run external snapshot pipelines from the primary region
6. **Testing**: Regularly test failover procedures

## Troubleshooting

### High Replication Lag

1. Check network latency between regions
2. Verify follower has sufficient CPU/IO capacity
3. Consider S3 transport for high-latency links
4. Check `ship_queue_depth` metric for backpressure

### Follower Not Receiving Updates

1. Verify `--primary-region` endpoint is correct
2. Check firewall allows TCP 3000/3001 between regions
3. Check primary logs for shipping errors
4. Verify S3 bucket permissions (if using S3 transport)

## Related Documentation

- [Error Codes Reference](error-codes.md) - Multi-region error codes
- [Disaster Recovery](disaster-recovery.md) - External snapshot recovery procedures
- [Operations Runbook](operations-runbook.md) - Day-to-day operations
