# Change: Geo-Routing Based on Client Location

Auto-route clients to nearest regional cluster based on geographic location.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~40 hours)

## Spec Deltas

- [specs/client-sdk/spec.md](specs/client-sdk/spec.md) - Region discovery, failover, metrics

## Summary

Enables automatic region selection and failover for global deployments:

```python
# Single endpoint - automatic region selection
client = ArcherDBClient(
    discovery_endpoint="https://archerdb.example.com/regions"
)
```

## How It Works

1. **Geo-DNS**: Initial request routes to nearest region
2. **Discovery**: Client fetches list of all regions
3. **Probing**: Background measurement of RTT to each region
4. **Selection**: Connect to lowest-latency healthy region
5. **Failover**: Automatic switch on region failure

```
Client → Geo-DNS → Nearest Region → /regions → [US, EU, APAC]
                                                     │
                                    Probe latencies ─┘
                                                     │
                                    Select lowest ───┘
```

## Configuration

```python
# Full configuration
client = ArcherDBClient(
    discovery_endpoint="https://archerdb.example.com/regions",
    preferred_region="us-east-1",      # Hint, not mandatory
    failover_enabled=True,              # Default: true
    probe_interval_ms=30000             # Default: 30s
)

# Direct connection (skip geo-routing)
client = ArcherDBClient(
    endpoint="archerdb-use1.example.com:5000"
)
```

## Metrics

```
archerdb_client_region_latency_ms{region="us-east-1"} 25
archerdb_client_region_latency_ms{region="eu-west-1"} 85
archerdb_client_region_switches_total{from="us-east-1",to="eu-west-1"} 5
```

## Key Design Decisions

1. **Two-phase discovery**: Geo-DNS + latency probing
2. **Background probing**: Non-blocking RTT measurement
3. **Automatic failover**: 3 failures marks region unhealthy
4. **Recovery support**: Healed regions rejoin rotation
