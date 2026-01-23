# ArcherDB Prometheus Alerting Rules

29 pre-configured alerting rules for proactive ArcherDB monitoring.

## Installation

### Copy Rules to Prometheus

```bash
# Copy rule files
sudo cp observability/prometheus/rules/*.yaml /etc/prometheus/rules/

# Verify syntax
promtool check rules /etc/prometheus/rules/archerdb-*.yaml
```

### Configure Prometheus

Add to `prometheus.yml`:

```yaml
rule_files:
  - /etc/prometheus/rules/archerdb-*.yaml
```

### Reload Configuration

```bash
# Option 1: SIGHUP
kill -HUP $(pidof prometheus)

# Option 2: API (requires --web.enable-lifecycle)
curl -X POST http://localhost:9090/-/reload
```

### Verify Rules Loaded

```bash
curl http://localhost:9090/api/v1/rules | jq '.data.groups[].name'
```

## Alert Files

### archerdb-warnings.yaml

12 warning-level alerts for early detection:

| Alert | Threshold | Duration | Purpose |
|-------|-----------|----------|---------|
| HighQueryLatencyWarning | p99 > 500ms | 5m | Query performance degradation |
| HighWriteLatencyWarning | p99 > 500ms | 5m | Write performance degradation |
| ReplicationLagTimeWarning | > 30s | 2m | Replica falling behind |
| ReplicationLagOpsWarning | > 1000 ops | 2m | Replica falling behind |
| HighMemoryUsageWarning | > 70% | 5m | Memory pressure building |
| HighDiskUsageWarning | > 100GB | 5m | Storage growth |
| ErrorRateWarning | > 0.1/sec | 5m | Write errors occurring |
| HighIndexLoadFactorWarning | > 70% | 5m | Index approaching capacity |
| HighTombstoneRatioWarning | > 10% | 5m | Deletions accumulating |
| CompactionStallWarning | > 10s | 5m | Compaction delays |
| HighWriteAmplificationWarning | > 15x | 5m | Storage efficiency issue |
| ViewChangeFrequencyWarning | > 3/hour | 5m | Cluster instability |

### archerdb-critical.yaml

17 critical-level alerts for immediate response:

| Alert | Threshold | Duration | Purpose |
|-------|-----------|----------|---------|
| HighQueryLatencyCritical | p99 > 2s | 5m | Severe query degradation |
| HighWriteLatencyCritical | p99 > 2s | 5m | Severe write degradation |
| ReplicationLagTimeCritical | > 2min | 2m | Replica significantly behind |
| ReplicationLagOpsCritical | > 10000 ops | 2m | Replica significantly behind |
| HighMemoryUsageCritical | > 85% | 5m | OOM risk |
| NodeDown | up == 0 | 1m | Node unreachable |
| ErrorRateCritical | > 1/sec | 2m | High error rate |
| UnhealthyShards | < 75% healthy | 2m | Cluster degraded |
| HighIndexLoadFactorCritical | > 90% | 5m | Index near capacity |
| HighTombstoneRatioCritical | > 30% | 5m | Compaction needed |
| CompactionStallCritical | > 30s | 5m | Severe compaction delay |
| HighWriteAmplificationCritical | > 30x | 5m | Severe storage issue |
| ViewChangeFrequencyCritical | > 10/hour | 2m | Severe cluster instability |
| CheckpointFailure | duration > 5min | 5m | Checkpoint stuck |
| DiskIOLatencyCritical | p99 > 100ms | 5m | Disk performance issue |
| ConnectionExhaustion | > 90% | 5m | Connection limit risk |
| PrimaryNotReachable | is_primary == 0 for all | 1m | No primary elected |

## Alert Annotations

All alerts include these annotations:

| Annotation | Purpose |
|------------|---------|
| `summary` | One-line alert description |
| `description` | Detailed info with current values |
| `runbook_url` | Link to troubleshooting guide |
| `remediation` | Quick fix suggestion |

Example:
```yaml
annotations:
  summary: "High query latency on {{ $labels.instance }}"
  description: "p99 query latency is {{ $value | humanizeDuration }} (threshold: 500ms)"
  runbook_url: "https://docs.archerdb.io/runbooks/high-query-latency"
  remediation: "Check for slow queries, index health, or resource contention"
```

## Severity Labels

Alerts use severity labels for routing:

| Severity | Routing Destination |
|----------|---------------------|
| `warning` | Slack, dashboard indicators |
| `critical` | PagerDuty, immediate response |

Configure Alertmanager routing:
```yaml
route:
  routes:
    - match:
        severity: critical
      receiver: 'archerdb-pagerduty-critical'
    - match:
        severity: warning
      receiver: 'archerdb-slack-warnings'
```

## Customizing Thresholds

### Edit Rule Files

Modify threshold values in YAML:

```yaml
# Original
expr: histogram_quantile(0.99, ...) > 0.5  # 500ms

# Custom (more sensitive)
expr: histogram_quantile(0.99, ...) > 0.3  # 300ms
```

### Adjust Duration

Change `for` duration for sensitivity:

```yaml
# Original (waits 5 minutes)
for: 5m

# Custom (fires faster)
for: 2m
```

### Add Team Labels

Add routing labels:

```yaml
labels:
  severity: critical
  team: database      # Route to database team
  environment: prod   # Filter by environment
```

## Prometheus Recording Rules

For heavy queries, consider adding recording rules:

```yaml
groups:
  - name: archerdb-recording
    rules:
      - record: archerdb:read_latency_p99:5m
        expr: histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket[5m])) by (le, instance))

      - record: archerdb:write_throughput:5m
        expr: sum(rate(archerdb_write_operations_total[5m])) by (instance)
```

Then reference in alerts:
```yaml
expr: archerdb:read_latency_p99:5m > 0.5
```

## Testing Alerts

### Verify Syntax

```bash
promtool check rules observability/prometheus/rules/*.yaml
```

### Test PromQL Expressions

In Prometheus UI:
```promql
# Test latency alert expression
histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket[5m])) by (le, instance)) > 0.5

# Test memory alert expression
(archerdb_memory_used_bytes / archerdb_memory_allocated_bytes) * 100 > 70
```

### Simulate Alert

Temporarily lower threshold to trigger:
```yaml
# Test: lower threshold to fire
expr: archerdb_memory_used_bytes / archerdb_memory_allocated_bytes > 0.01  # 1%
```

## Silencing Alerts

During maintenance:

```bash
# Create silence via amtool
amtool silence add alertname="ArcherDBNodeDown" instance="archerdb-node-1:9100" \
  --comment "Planned maintenance" --duration 2h

# List silences
amtool silence query

# Expire silence
amtool silence expire <silence-id>
```

## Troubleshooting

### Alert Not Firing

1. Check rule is loaded: `curl localhost:9090/api/v1/rules`
2. Check expression returns data in Prometheus UI
3. Check `for` duration hasn't elapsed
4. Check Alertmanager is receiving alerts

### Alert Firing When Shouldn't

1. Check metric values in Prometheus UI
2. Verify threshold is appropriate for your workload
3. Check for label mismatches in filter expressions

### Runbook URLs Not Working

Runbook URLs point to `https://docs.archerdb.io/runbooks/*` which will be populated in Phase 9 (Documentation). For now, use the `remediation` annotation for quick guidance.
