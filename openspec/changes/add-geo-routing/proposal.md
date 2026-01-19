# Proposal: Geo-Routing Based on Client Location

## Summary

Auto-route clients to the nearest regional cluster based on their geographic location, reducing latency for global deployments.

## Motivation

### Problem

Global deployments have clusters in multiple regions (US, EU, APAC). Currently, clients must be configured with the correct regional endpoint manually:

```yaml
# Manual configuration per region
production-us:
  endpoint: archerdb-us.example.com:5000
production-eu:
  endpoint: archerdb-eu.example.com:5000
```

This creates operational burden and doesn't handle mobile users who travel between regions.

### Current Behavior

- Clients connect to hardcoded endpoint
- No automatic region discovery
- Mobile users may connect to distant regions
- Failover requires manual intervention

### Desired Behavior

- **Geo-DNS**: Single global endpoint resolves to nearest region
- **Client-side routing**: SDKs discover and prefer nearby clusters
- **Automatic failover**: If nearest region fails, route to next-nearest
- **Latency awareness**: Route based on measured RTT, not just geography

## Scope

### In Scope

1. **Geo-DNS integration**: Guide for DNS-based routing
2. **Client discovery protocol**: Protocol for region discovery
3. **Latency probing**: Clients measure RTT to available regions
4. **Region preference**: SDK configuration for region affinity
5. **Failover routing**: Automatic failover to backup regions

### Out of Scope

1. **DNS infrastructure**: Use existing services (Route53, Cloudflare)
2. **Data replication between regions**: Separate spec
3. **Conflict resolution**: Handled by multi-region replication spec

## Success Criteria

1. **Latency reduction**: Clients connect to lowest-latency region
2. **Automatic failover**: Region failure triggers re-routing <30s
3. **No manual config**: Single endpoint for all regions

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Geo-DNS inaccuracy | Wrong region selected | Fall back to latency probing |
| Region discovery overhead | Increased connection time | Cache region list, probe in background |
| Split-brain during failover | Data inconsistency | Use multi-region replication with conflict resolution |

## Stakeholders

- **Global operators**: Need simplified multi-region deployment
- **Mobile app developers**: Need seamless region transitions
- **SRE teams**: Need automatic failover capability
