# ArcherDB Observability Stack

Production-ready monitoring for ArcherDB with Grafana dashboards, Prometheus alerting rules, and Alertmanager notification templates.

## Overview

```
observability/
├── grafana/
│   ├── dashboards/           # 5 Grafana dashboards (48 panels total)
│   │   ├── archerdb-overview.json
│   │   ├── archerdb-queries.json
│   │   ├── archerdb-replication.json
│   │   ├── archerdb-storage.json
│   │   └── archerdb-cluster.json
│   └── provisioning/
│       └── dashboards.yaml   # File provisioning config
├── prometheus/
│   └── rules/                # 29 alerting rules
│       ├── archerdb-warnings.yaml   # 12 warning rules
│       └── archerdb-critical.yaml   # 17 critical rules
└── alertmanager/
    ├── templates/            # 5 notification templates
    │   ├── slack.tmpl
    │   ├── pagerduty.tmpl
    │   ├── opsgenie.tmpl
    │   ├── email.tmpl
    │   └── webhook.tmpl
    └── README.md             # Alertmanager setup guide
```

## Quick Start

### 1. Grafana Dashboards

Copy dashboards and provisioning config:

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

Configure Prometheus as a datasource pointing to your ArcherDB metrics endpoint.

See [grafana/README.md](grafana/README.md) for detailed dashboard documentation.

### 2. Prometheus Alerting Rules

Add alerting rules to Prometheus:

```bash
# Copy rules
sudo cp observability/prometheus/rules/*.yaml /etc/prometheus/rules/

# Edit prometheus.yml to include rules
# rule_files:
#   - /etc/prometheus/rules/archerdb-*.yaml

# Reload Prometheus
curl -X POST http://localhost:9090/-/reload
```

See [prometheus/README.md](prometheus/README.md) for rule customization and threshold tuning.

### 3. Alertmanager Notifications

Copy receiver templates and configure routing:

```bash
# Edit alertmanager.yml
# 1. Copy receiver config from observability/alertmanager/templates/<channel>.tmpl
# 2. Replace placeholder values (<YOUR_SLACK_WEBHOOK_URL>, etc.)
# 3. Configure routing rules

# Reload Alertmanager
amtool check-config /etc/alertmanager/alertmanager.yml
curl -X POST http://localhost:9093/-/reload
```

See [alertmanager/README.md](alertmanager/README.md) for detailed setup and routing examples.

## Dashboards

| Dashboard | Panels | Purpose |
|-----------|--------|---------|
| Overview | 8 | Entry point - cluster health, throughput, latency, replication, memory |
| Queries | 10 | Deep dive - latency by type, error rates, index health |
| Replication | 8 | VSR state, lag (time & ops), view changes, primary status |
| Storage | 12 | LSM levels, compaction, disk I/O, memory breakdown, checkpoints |
| Cluster | 10 | Node health, connections, coordinator, shards |

All dashboards share common template variables:
- **datasource** - Prometheus datasource selector
- **instance** - Multi-select node filter
- **terminology** - Display customization (archerdb/database/plain)

## Alerting Rules

### Warning Alerts (Slack, dashboard indicators)

| Alert | Threshold | Duration |
|-------|-----------|----------|
| HighQueryLatencyWarning | p99 > 500ms | 5m |
| ReplicationLagTimeWarning | > 30s | 2m |
| ReplicationLagOpsWarning | > 1000 ops | 2m |
| HighMemoryUsageWarning | > 70% | 5m |
| HighDiskUsageWarning | > 100GB | 5m |
| ErrorRateWarning | > 0.1/sec | 5m |

### Critical Alerts (PagerDuty, immediate response)

| Alert | Threshold | Duration |
|-------|-----------|----------|
| HighQueryLatencyCritical | p99 > 2s | 5m |
| ReplicationLagTimeCritical | > 2min | 2m |
| ReplicationLagOpsCritical | > 10000 ops | 2m |
| HighMemoryUsageCritical | > 85% | 5m |
| NodeDown | up == 0 | 1m |
| ErrorRateCritical | > 1/sec | 2m |
| UnhealthyShards | < 75% healthy | 2m |

All alerts include:
- `runbook_url` - Link to troubleshooting documentation
- `remediation` - Quick fix suggestion
- `severity` label for routing

## Requirements

- Grafana 9.x or later (schemaVersion 39 dashboards)
- Prometheus 2.x or later
- Alertmanager 0.25.x or later
- ArcherDB with metrics endpoint enabled (`--metrics-address`)

## Metrics Endpoint

Enable ArcherDB metrics:

```bash
archerdb --metrics-address 0.0.0.0:9100
```

Default metrics port is 9100. Configure Prometheus scrape:

```yaml
scrape_configs:
  - job_name: 'archerdb'
    static_configs:
      - targets: ['archerdb-node-1:9100', 'archerdb-node-2:9100', 'archerdb-node-3:9100']
```

## Support

For issues with:
- **Dashboards** - See [grafana/README.md](grafana/README.md)
- **Alerts** - See [prometheus/README.md](prometheus/README.md)
- **Notifications** - See [alertmanager/README.md](alertmanager/README.md)
- **ArcherDB metrics** - See ArcherDB documentation (Phase 9)
