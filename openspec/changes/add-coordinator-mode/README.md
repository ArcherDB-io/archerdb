# Change: Optional Coordinator Node

This proposal formalizes the coordinator as a first-class deployment option, enabling dedicated query proxy nodes for complex multi-shard deployments.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design and implementation details
- [tasks.md](tasks.md) - Implementation tasks (30-38 hours estimated)

## Spec Deltas

- [specs/coordinator/spec.md](specs/coordinator/spec.md) - Coordinator mode requirements
- [specs/configuration/spec.md](specs/configuration/spec.md) - CLI arguments
- [specs/observability/spec.md](specs/observability/spec.md) - Coordinator metrics

## Summary

Adds `archerdb coordinator start` command for running dedicated coordinator nodes that:

- Route queries to appropriate shards (single-shard routing + fan-out)
- Load balance reads across shard replicas
- Monitor shard health and adapt routing
- Expose Prometheus metrics for coordinator operations

## Use When

Choose coordinator mode over smart clients when:

| Scenario | Coordinator Advantage |
|----------|----------------------|
| Many client languages | Single routing implementation |
| Serverless functions | No topology discovery on cold start |
| Network isolation | Single externally-exposed endpoint |
| Legacy applications | No SDK changes required |
| Central rate limiting | One place for global controls |

## Architecture

```
┌─────────────────────────────────────┐
│          Load Balancer              │
└─────────────────────────────────────┘
         │           │           │
         ▼           ▼           ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│Coordinator 1│ │Coordinator 2│ │Coordinator 3│
│ (stateless) │ │ (stateless) │ │ (stateless) │
└─────────────┘ └─────────────┘ └─────────────┘
         │           │           │
         └─────────┬─┴───────────┘
                   │
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
┌────────┐    ┌────────┐    ┌────────┐
│Shard 0 │    │Shard 1 │    │Shard N │
└────────┘    └────────┘    └────────┘
```

## Key Design Decisions

1. **Stateless shared-nothing**: Each coordinator discovers topology independently
2. **Connection per shard**: Dedicated connections, no multiplexing
3. **Configurable fan-out**: strict/partial/best_effort policies
4. **Round-robin load balancing**: Health-aware replica selection

## Example Usage

```bash
# Start with explicit shards
archerdb coordinator start \
  --bind=0.0.0.0:5000 \
  --shards=shard-0:5001,shard-1:5001,shard-2:5001

# Start with seed discovery
archerdb coordinator start \
  --bind=0.0.0.0:5000 \
  --seed-nodes=node-0:5001,node-5:5001 \
  --max-connections=10000

# Check status
archerdb coordinator status
```

## Dependencies

- Base: `configuration/spec.md` (CLI framework)
- Base: `observability/spec.md` (metrics endpoint)
- Base: `index-sharding/query-routing.md` (routing algorithm)
