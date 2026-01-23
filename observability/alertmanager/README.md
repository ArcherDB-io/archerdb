# ArcherDB Alertmanager Templates

These templates provide receiver configurations for common notification channels.
Copy the relevant template content into your `alertmanager.yml` file.

## Available Templates

| Template | Channel | Use Case |
|----------|---------|----------|
| `slack.tmpl` | Slack | Team notifications, warning alerts |
| `pagerduty.tmpl` | PagerDuty | On-call paging, incident management |
| `opsgenie.tmpl` | OpsGenie | On-call scheduling, alert routing |
| `email.tmpl` | Email | Backup notifications, digests |
| `webhook.tmpl` | Generic HTTP | Custom integrations, automation |

## Quick Start

1. Choose templates for your notification channels
2. Copy receiver configurations to your `alertmanager.yml`
3. Replace placeholder values (e.g., `<YOUR_SLACK_WEBHOOK_URL>`)
4. Configure routing rules to direct alerts appropriately
5. Test with `amtool check-config alertmanager.yml`

## Example alertmanager.yml

```yaml
global:
  resolve_timeout: 5m
  # SMTP settings for email (if using)
  # smtp_smarthost: 'smtp.example.com:587'
  # smtp_from: 'alertmanager@example.com'
  # smtp_auth_username: 'alertmanager@example.com'
  # smtp_auth_password: '<PASSWORD>'

route:
  receiver: 'archerdb-slack-warnings'
  group_by: ['alertname', 'instance']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Critical alerts go to PagerDuty AND Slack
    - match:
        severity: critical
      receiver: 'archerdb-pagerduty-critical'
      group_wait: 10s
      repeat_interval: 1h
      continue: true  # Also send to Slack
    - match:
        severity: critical
      receiver: 'archerdb-slack-critical'
    # Warnings go to Slack only
    - match:
        severity: warning
      receiver: 'archerdb-slack-warnings'

receivers:
  # Copy receiver configs from templates here
  - name: 'archerdb-slack-warnings'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/...'
        channel: '#archerdb-alerts'
        # ... rest from slack.tmpl

  - name: 'archerdb-slack-critical'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/...'
        channel: '#archerdb-alerts-critical'
        # ... rest from slack.tmpl

  - name: 'archerdb-pagerduty-critical'
    pagerduty_configs:
      - routing_key: 'your-routing-key'
        # ... rest from pagerduty.tmpl

inhibit_rules:
  # Don't send warning if critical is already firing
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']
```

## Alert Annotations

All ArcherDB alerts include these annotations for rich notifications:

| Annotation | Description |
|------------|-------------|
| `summary` | Brief one-line description of the alert |
| `description` | Detailed information including current metric values |
| `runbook_url` | Link to troubleshooting documentation |
| `remediation` | Quick fix suggestion for first responders |

## Severity Levels

| Severity | Response | Typical Routing |
|----------|----------|-----------------|
| `critical` | Immediate (page) | PagerDuty/OpsGenie + Slack critical channel |
| `warning` | Soon (during business hours) | Slack warnings channel |

## Testing Alerts

Send a test alert to verify your configuration:

```bash
# Using amtool (comes with Alertmanager)
amtool alert add alertname=TestAlert severity=warning \
  instance=test-instance:8080 \
  --annotation.summary="Test alert from amtool" \
  --annotation.description="This is a test alert" \
  --annotation.runbook_url="https://docs.archerdb.io/runbooks/test" \
  --annotation.remediation="No action needed, this is a test"

# Using curl
curl -XPOST http://localhost:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "warning",
      "instance": "test-instance:8080"
    },
    "annotations": {
      "summary": "Test alert from curl",
      "description": "This is a test alert",
      "runbook_url": "https://docs.archerdb.io/runbooks/test",
      "remediation": "No action needed, this is a test"
    }
  }]'
```

## Silencing Alerts

During maintenance windows, silence alerts to prevent noise:

```bash
# Silence all alerts for an instance during maintenance
amtool silence add alertname=~"ArcherDB.*" instance="node1:8080" \
  --author="your-name" \
  --comment="Scheduled maintenance" \
  --duration=2h

# Silence a specific alert
amtool silence add alertname="ArcherDBHighMemoryUsageWarning" \
  --author="your-name" \
  --comment="Known issue, fix scheduled" \
  --duration=24h
```

## Related Files

- `../prometheus/rules/archerdb-warnings.yaml` - Warning-level alert rules
- `../prometheus/rules/archerdb-critical.yaml` - Critical-level alert rules
- `../grafana/dashboards/` - Dashboards showing alert-related metrics

## Resources

- [Alertmanager Documentation](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [ArcherDB Runbooks](https://docs.archerdb.io/runbooks/) (Phase 9)
