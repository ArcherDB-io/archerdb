# ArcherDB Grafana Dashboards

5 pre-built dashboards with 48 panels for comprehensive ArcherDB monitoring.

## Installation

### Option 1: File Provisioning (Recommended)

```bash
# Create dashboard directory
sudo mkdir -p /etc/grafana/dashboards/archerdb

# Copy dashboards
sudo cp observability/grafana/dashboards/*.json /etc/grafana/dashboards/archerdb/

# Copy provisioning config
sudo cp observability/grafana/provisioning/dashboards.yaml /etc/grafana/provisioning/dashboards/

# Restart Grafana
sudo systemctl restart grafana-server
```

### Option 2: Manual Import

1. Open Grafana UI
2. Navigate to Dashboards → Import
3. Upload each JSON file from `observability/grafana/dashboards/`
4. Select your Prometheus datasource
5. Click Import

### Option 3: Kubernetes ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: archerdb-dashboards
  labels:
    grafana_dashboard: "1"
data:
  archerdb-overview.json: |
    # Contents of archerdb-overview.json
```

## Dashboards

### Overview Dashboard

**UID:** `archerdb-overview`
**Entry point** for ArcherDB monitoring.

| Panel | Metric | Description |
|-------|--------|-------------|
| Cluster Health | `archerdb_health_status` | Worst health status across nodes (0=healthy) |
| Active Nodes | `archerdb_health_status` | Healthy/total node count |
| Write Throughput | `archerdb_write_operations_total` | Operations/sec by type (insert, upsert, delete) |
| Read Throughput | `archerdb_read_operations_total` | Operations/sec by type (uuid, radius, polygon, latest) |
| Write Latency | `archerdb_write_latency_seconds` | p50/p95/p99 latency |
| Read Latency | `archerdb_read_latency_seconds` | p50/p95/p99 latency |
| Replication Lag | `archerdb_vsr_replication_lag_seconds` | Time and ops behind primary |
| Memory Usage | `archerdb_memory_used_bytes` | Percentage with 70%/85% thresholds |

### Queries Dashboard

**UID:** `archerdb-queries`
**Deep dive** into query performance.

| Panel | Purpose |
|-------|---------|
| Read Latency by Query Type | p99 latency for uuid/radius/polygon/latest |
| Write Latency by Operation | p99 latency for insert/upsert/delete |
| Read Operations Rate | Stacked ops/sec by type |
| Write Operations Rate | Stacked ops/sec by type |
| Events Processed | Read/write events per second |
| Write Bytes | Data throughput |
| Error Rate | Write errors/sec (zero baseline) |
| Index Lookup Latency | p50/p95/p99 for index operations |
| Index Load Factor | Gauge with 70%/90% thresholds |
| Tombstone Ratio | Gauge with 10%/30% thresholds |

### Replication Dashboard

**UID:** `archerdb-replication`
**VSR consensus** monitoring for technical operators.

| Panel | Purpose |
|-------|---------|
| Node Status | Table: instance, VSR status, primary, view, op number |
| Current View | Stat with sparkline |
| Lag by Time | Time series with 30s/120s thresholds |
| Lag by Operations | Time series with 1000/10000 thresholds |
| View Changes | Leader election frequency |
| Operation Number | Commit progress per node |
| Primary Node | Current primary instance |
| Replica Health | Derived healthy/degraded/unhealthy state |

**Annotations:**
- Orange: View changes (potential failover)
- Red: Primary changes (leader election)

### Storage Dashboard

**UID:** `archerdb-storage`
**LSM tree** and disk monitoring.

| Panel | Purpose |
|-------|---------|
| LSM Level Sizes | Stacked area L0-L6 |
| Tables per Level | Bar chart by level |
| Compaction Duration | p50/p95/p99 |
| Compaction Throughput | Read vs write bytes/sec |
| Write Amplification Ratio | With 15x/30x thresholds |
| Compactions/hour | Stat |
| Disk Read Latency | p50/p95/p99 with 10ms threshold |
| Disk Write Latency | p50/p95/p99 with 10ms threshold |
| Memory by Component | Stacked: RAM Index, Cache, Other |
| Data File Size | Storage growth tracking |
| Checkpoint Duration | p50/p95/p99 |
| Checkpoints/hour | Stat |

### Cluster Dashboard

**UID:** `archerdb-cluster`
**Node and coordinator** monitoring.

| Panel | Purpose |
|-------|---------|
| Node Overview | Table with health, version, uptime, connections |
| Healthy Nodes | Percentage stat |
| Active Connections | Per instance |
| Connection Errors | Per instance |
| Coordinator Query Rate | Single vs fanout queries |
| Coordinator Query Duration | p50/p95/p99 |
| Total Shards | Stat |
| Healthy Shards % | Gauge with 90%/75% thresholds |
| Version Info | Table with build info |
| Uptime | Per node |

## Template Variables

All dashboards share these variables:

| Variable | Type | Purpose |
|----------|------|---------|
| `datasource` | Datasource | Prometheus datasource selector |
| `instance` | Query | Multi-select node filter from `archerdb_info` |
| `terminology` | Custom | Display mode: archerdb/database/plain |

### Using the Terminology Toggle

Switch between display modes:
- **archerdb** - Technical terms (VSR, LSM, S2)
- **database** - Generic database terms
- **plain** - Plain English descriptions

## Thresholds

### Latency Panels
- **Yellow:** 500ms
- **Red:** 2s

### Memory Panels
- **Yellow:** 70%
- **Red:** 85%

### Index Load Factor
- **Yellow:** 70%
- **Red:** 90%

### Tombstone Ratio
- **Yellow:** 10%
- **Red:** 30%

### Replication Lag
- **Yellow:** 30s / 1000 ops
- **Red:** 120s / 10000 ops

## Dashboard Links

All dashboards link to each other for navigation:
- Overview → Queries, Replication, Storage, Cluster
- Detail dashboards → Back to Overview + other details

## Troubleshooting

### No Data

1. Verify Prometheus datasource is configured
2. Check ArcherDB metrics endpoint is reachable
3. Verify instance labels match your deployment
4. Check time range includes recent data

### Variable Query Errors

Ensure Prometheus has scraped ArcherDB at least once:
```promql
archerdb_info
```

### Dashboard Import Errors

- Check Grafana version is 9.x or later
- Verify JSON files are not corrupted
- Check datasource UID matches your Prometheus datasource

## Customization

### Adding Custom Panels

1. Open dashboard in Grafana
2. Add new panel
3. Use PromQL with `archerdb_*` metrics
4. Apply `$instance` filter: `{instance=~"$instance"}`
5. Export updated JSON

### Changing Thresholds

Edit JSON files or use Grafana UI:
```json
"thresholds": {
  "steps": [
    {"value": null, "color": "green"},
    {"value": 0.5, "color": "yellow"},
    {"value": 2, "color": "red"}
  ]
}
```

### Adding Annotations

Add custom event markers:
```json
{
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "enable": true,
  "expr": "your_event_metric > 0",
  "iconColor": "blue",
  "name": "Custom Event"
}
```
