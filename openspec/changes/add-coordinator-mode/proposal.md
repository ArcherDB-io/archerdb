# Proposal: Optional Coordinator Node

## Summary

Formalize the coordinator as a first-class deployment option, enabling dedicated query proxy nodes for complex multi-shard deployments where smart clients are impractical.

## Motivation

### Problem

The current architecture recommends "smart clients" that maintain topology and route queries directly to shards. This works well for simple deployments but has limitations:

| Challenge | Smart Client Impact |
|-----------|---------------------|
| Many client languages | Must implement routing in each SDK |
| Legacy clients | Can't modify existing applications |
| Serverless functions | Cold starts expensive with topology discovery |
| Network isolation | Clients may not have direct shard access |
| Debugging | Distributed tracing across many clients |
| Rate limiting | Hard to enforce globally |

### Current Behavior

- `src/coordinator.zig` exists with basic implementation
- Spec says "v2.1+: Optional coordinator for complex deployments"
- No CLI support for running coordinator mode
- No formal spec for coordinator behavior
- No HA/clustering for coordinators

### Desired Behavior

- **`archerdb coordinator`** command to run dedicated coordinator
- **Simple clients** connect only to coordinator (standard TCP/gRPC)
- **HA coordinators** with automatic failover
- **Observability** with dedicated coordinator metrics
- **Documentation** for when to use coordinator vs smart client

## Scope

### In Scope

1. **Coordinator mode CLI**: `archerdb coordinator start --shards=...`
2. **Coordinator configuration**: Bind address, timeouts, pool sizes
3. **Fan-out query execution**: Parallel shard queries with aggregation
4. **Load balancing**: Round-robin across shard replicas
5. **Health monitoring**: Track shard health, automatic failover
6. **HA clustering**: Multiple coordinators with shared-nothing state
7. **Metrics**: Coordinator-specific Prometheus metrics
8. **Simple protocol**: Standard wire protocol for dumb clients

### Out of Scope

1. **Query caching**: Coordinators are stateless proxies
2. **Connection multiplexing**: Each client gets dedicated shard connections
3. **Automatic coordinator election**: Manual deployment, use load balancer
4. **Query rewriting**: Pass-through only, no query optimization

## Success Criteria

1. **Deployment option**: Can run coordinator with `archerdb coordinator start`
2. **Simple clients**: Clients need only coordinator address, not shard topology
3. **Performance**: <1ms additional latency vs smart client
4. **HA**: Coordinator failure handled by load balancer failover
5. **Observability**: Dedicated metrics for coordinator health and performance

## Use Cases

### Use Case 1: Multi-Language Environment

```
┌────────────┐    ┌─────────────┐    ┌─────────┐
│ Python App │───>│             │───>│ Shard 0 │
└────────────┘    │             │    └─────────┘
┌────────────┐    │ Coordinator │    ┌─────────┐
│ Go Service │───>│   (Proxy)   │───>│ Shard 1 │
└────────────┘    │             │    └─────────┘
┌────────────┐    │             │    ┌─────────┐
│ Legacy App │───>│             │───>│ Shard N │
└────────────┘    └─────────────┘    └─────────┘
```

All apps use simple TCP protocol; coordinator handles routing.

### Use Case 2: Serverless Functions

```
┌──────────────┐
│ Lambda/Cloud │     ┌─────────────┐    ┌──────────┐
│  Functions   │────>│ Coordinator │───>│ Shards   │
│ (cold start) │     └─────────────┘    └──────────┘
└──────────────┘
```

Functions connect to single coordinator; no topology discovery needed.

### Use Case 3: Network-Isolated Clients

```
┌─────────────────────┐    ┌───────────────────────────┐
│   Public Network    │    │    Private Network        │
│                     │    │                           │
│  ┌────────────┐     │    │   ┌─────────────┐         │
│  │   Client   │─────┼────┼──>│ Coordinator │─┐       │
│  └────────────┘     │    │   └─────────────┘ │       │
│                     │    │                   │       │
│                     │    │   ┌─────────┐     │       │
│                     │    │   │ Shard 0 │<────┘       │
│                     │    │   └─────────┘             │
│                     │    │   ┌─────────┐             │
│                     │    │   │ Shard N │<────────────│
│                     │    │   └─────────┘             │
└─────────────────────┘    └───────────────────────────┘
```

Coordinator is the only externally-exposed endpoint.

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Coordinator bottleneck | Throughput limit | Scale out with multiple coordinators behind LB |
| Single point of failure | Availability impact | Deploy 2+ coordinators, use health checks |
| Additional latency | Performance degradation | Keep coordinators close to shards (<1ms network) |
| Complexity | Operational burden | Document when smart client is preferred |

## Stakeholders

- **Operators**: Need simpler client deployment for diverse environments
- **SDK maintainers**: Benefit from simpler client implementations
- **Security team**: Need single ingress point for audit/firewall
- **Platform team**: Need serverless-friendly deployment option

## Related Work

- Existing: `src/coordinator.zig` (basic implementation)
- Reference: Redis Cluster Proxy, MySQL Router, PgBouncer
- Related spec: `index-sharding/query-routing.md`
