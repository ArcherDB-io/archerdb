# Proposal: Dynamic Cluster Membership

## Summary

Enable adding and removing nodes from a running cluster without downtime, supporting elastic scaling and zero-downtime maintenance.

## Motivation

### Problem

Current VSR implementation requires fixed replica count at cluster formation:

```bash
# Cluster formed with 5 replicas - can't change
archerdb cluster format --replica-count=5
```

To add/remove nodes:
1. Stop the entire cluster
2. Reformat with new replica count
3. Restore data from backup
4. Restart

This causes significant downtime and operational complexity.

### Current Behavior

- Replica count fixed at cluster creation
- No mechanism for membership changes
- Adding capacity requires new cluster + migration
- Maintenance requires taking node offline

### Desired Behavior

- **Add nodes**: Join new replicas to running cluster
- **Remove nodes**: Gracefully remove replicas without data loss
- **Automatic rebalancing**: Data redistributes to new members
- **Zero downtime**: Operations continue during membership changes

## Scope

### In Scope

1. **Membership change protocol**: VSR reconfiguration extension
2. **Node join workflow**: New node catches up and joins
3. **Node leave workflow**: Graceful departure with state transfer
4. **Rebalancing**: Data movement to new nodes
5. **CLI commands**: `archerdb cluster add-node`, `archerdb cluster remove-node`

### Out of Scope

1. **Automatic scaling**: Triggered by operator only
2. **Cross-region membership**: Same-region clusters only
3. **Shard rebalancing**: Focus on replica membership, not resharding

## Success Criteria

1. **Zero downtime**: Operations continue during changes
2. **Data safety**: No data loss during membership changes
3. **Bounded catch-up**: New nodes operational within SLA
4. **Graceful degradation**: Handles partial failures during change

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Split-brain during reconfiguration | Data loss | Use VSR view change protocol |
| Slow node catch-up | Degraded performance | Throttle catch-up, prioritize queries |
| Failed membership change | Cluster stuck | Automatic rollback on timeout |
| Concurrent membership changes | Inconsistency | Serialize changes, one at a time |

## Stakeholders

- **Cloud operators**: Need elastic scaling
- **SRE teams**: Need zero-downtime maintenance
- **Platform teams**: Need self-healing infrastructure
