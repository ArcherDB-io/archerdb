# ArcherDB Monitoring

This directory contains monitoring configurations for ArcherDB deployments.

## Grafana Dashboard

### Quick Import

1. Open Grafana (default: http://localhost:3000)
2. Go to **Dashboards** → **Import**
3. Upload `grafana/archerdb-dashboard.json`
4. Select your Prometheus data source
5. Click **Import**

### Dashboard Overview

The ArcherDB Operations Dashboard includes the following sections:

| Section | Purpose | Key Metrics |
|---------|---------|-------------|
| **Executive Summary** | High-level SLO status | Cluster health, write throughput, entity count |
| **Query Latency** | SLO tracking for all query types | UUID, radius, polygon latencies (p50/p99) |
| **Operational Health** | On-call monitoring | Checkpoint age, tombstone ratio, compaction debt |
| **Performance Tuning** | Engineering deep dives | Cache hit ratio, S2 efficiency, disk I/O |
| **Replication & VSR** | Cluster consensus | View changes, replica lag, bandwidth |
| **Errors & Alerts** | Critical failure indicators | Corruption, hash mismatches, memory exhaustion |
| **Memory & Resources** | Resource utilization | Index memory, fragmentation, CPU usage |

### SLO Thresholds

The dashboard includes visual thresholds for key SLOs:

| Metric | p50 Target | p99 Target | Alert |
|--------|------------|------------|-------|
| UUID Lookup | < 200μs | < 500μs | > 1ms |
| Radius Query | < 20ms | < 50ms | > 100ms |
| Polygon Query | < 40ms | < 100ms | > 200ms |
| Write Latency | < 2ms | < 5ms | > 10ms |
| View Change | - | < 100ms | > 500ms |

### Critical Alerts Panel

The following metrics have CRITICAL severity and should page on-call:

- **S2 Verification Failures**: S2 cell ID divergence detected → Panic
- **Superblock Checksum Failures**: Data file corruption
- **VSR Hash Mismatch**: Replication chain divergence → Panic
- **Memory Exhaustion**: Out-of-memory error → Panic
- **Corruption Detected**: Storage/hash/checksum corruption
- **Checkpoint Corruption**: Checkpoint file integrity failure

All critical metrics should be `= 0` during normal operation.

## Prometheus Configuration

Add the following scrape config to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'archerdb'
    static_configs:
      - targets: ['localhost:9090']  # ArcherDB metrics endpoint
    scrape_interval: 10s
    metrics_path: /metrics
```

For multi-node clusters:

```yaml
scrape_configs:
  - job_name: 'archerdb'
    static_configs:
      - targets:
        - 'node1:9090'
        - 'node2:9090'
        - 'node3:9090'
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        regex: '([^:]+).*'
        replacement: '${1}'
```

## Alert Rules

### Example Alertmanager Integration

```yaml
# prometheus/alert_rules.yml
groups:
  - name: archerdb_critical
    rules:
      - alert: ArcherDBCorruption
        expr: archerdb_corruption_detected_total > 0
        for: 0s
        labels:
          severity: critical
        annotations:
          summary: "Data corruption detected"
          description: "{{ $labels.component }} corruption on {{ $labels.instance }}"

      - alert: ArcherDBIndexCapacity
        expr: archerdb_index_load_factor > 0.75
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Index capacity critical"
          description: "Load factor {{ $value | humanizePercentage }} on {{ $labels.instance }}"
```

## Directory Structure

```
monitoring/
├── README.md                          # This file
├── grafana/
│   └── archerdb-dashboard.json        # Grafana dashboard
└── prometheus/                        # (Future) Prometheus configs
    └── alert_rules.yml                # (Future) Alert rules
```
