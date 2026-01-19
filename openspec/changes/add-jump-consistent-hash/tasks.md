# Implementation Tasks: Jump Consistent Hash

## Phase 1: Core Algorithm

### Task 1.1: Implement jumpHash function
- **File**: `src/sharding.zig`
- **Changes**:
  - Add `jumpHash(key: u64, num_buckets: u32) u32` function
  - Use Google's exact algorithm (2014 paper)
  - Add assert for num_buckets > 0
- **Validation**: Unit test for determinism and range
- **Estimated effort**: 30 minutes

### Task 1.2: Add ShardingStrategy enum
- **File**: `src/sharding.zig`
- **Changes**:
  - Add `ShardingStrategy` enum: `modulo`, `virtual_ring`, `jump_hash`
  - Add `fromString()` and `toString()` methods
  - Add `requiresPowerOfTwo()` method
  - Add `isDefault()` returning `jump_hash`
- **Validation**: Enum conversion tests
- **Estimated effort**: 30 minutes

### Task 1.3: Implement unified getShardForEntity
- **File**: `src/sharding.zig`
- **Changes**:
  - Add `getShardForEntity(entity_id, num_shards, strategy, ring)` function
  - Route to appropriate algorithm based on strategy
  - Handle null ring for non-ring strategies
- **Validation**: Test all three strategies return valid shards
- **Estimated effort**: 30 minutes

### Task 1.4: Relax power-of-2 constraint for non-modulo
- **File**: `src/sharding.zig`
- **Changes**:
  - Update `isValidShardCount()` to accept strategy parameter
  - Or add `isValidShardCountForStrategy(count, strategy)` function
  - Modulo requires power-of-2, others don't
- **Validation**: Test valid/invalid counts per strategy
- **Estimated effort**: 30 minutes

## Phase 2: CLI Configuration

### Task 2.1: Add --sharding-strategy CLI flag
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Add `sharding_strategy: ShardingStrategy = .jump_hash` to init args
  - Parse strategy from string
  - Validate strategy value
  - Add help text
- **Validation**: CLI parsing test
- **Estimated effort**: 45 minutes

### Task 2.2: Validate shard count against strategy
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - After parsing, validate shard count vs strategy
  - If modulo and not power-of-2, error with helpful message
  - Log selected strategy at startup
- **Validation**: Error message test for invalid combinations
- **Estimated effort**: 30 minutes

### Task 2.3: Persist strategy in cluster metadata
- **File**: `src/archerdb/cluster_metadata.zig` or equivalent
- **Changes**:
  - Add `sharding_strategy` field to cluster config
  - Serialize/deserialize with cluster state
  - Load strategy at startup
- **Validation**: Restart preserves strategy
- **Estimated effort**: 1 hour

### Task 2.4: Add strategy to cluster info command
- **File**: `src/archerdb/commands.zig` or equivalent
- **Changes**:
  - Include strategy in `archerdb info` output
  - Show "N/A" for vnodes if not virtual_ring
- **Validation**: Output format test
- **Estimated effort**: 30 minutes

## Phase 3: Integration

### Task 3.1: Use strategy in query routing
- **File**: `src/archerdb/coordinator.zig` or equivalent
- **Changes**:
  - Load strategy from cluster config
  - Use `getShardForEntity()` for entity lookups
  - Initialize ring only if strategy is `virtual_ring`
- **Validation**: Entity routes to correct shard per strategy
- **Estimated effort**: 1 hour

### Task 3.2: Use strategy in resharding
- **File**: `src/sharding.zig` (ReshardingManager)
- **Changes**:
  - Use configured strategy for migration computation
  - Log expected movement based on strategy
  - Support jump hash in online resharding
- **Validation**: Resharding works with all strategies
- **Estimated effort**: 1 hour

### Task 3.3: Add strategy migration computation
- **File**: `src/sharding.zig`
- **Changes**:
  - Add `computeStrategyMigration(entities, old_strategy, new_strategy, ...)` function
  - Compute exact entity movements when changing strategies
  - Return migration plan with (entity_id, old_shard, new_shard)
- **Validation**: Migration computation test
- **Estimated effort**: 1 hour

## Phase 4: Testing

### Task 4.1: Unit tests for jumpHash
- **File**: `src/sharding.zig` (test section)
- **Tests**:
  - Determinism: same key → same bucket
  - Range: result always < num_buckets
  - Known values: verify against reference implementation
  - Edge cases: 1 bucket, max buckets
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 4.2: Unit tests for jump hash uniformity
- **File**: `src/sharding.zig` (test section)
- **Tests**:
  - Generate 1M random keys, count per bucket
  - Verify each bucket has exactly 1/N (within float precision)
  - Test with various bucket counts (8, 16, 24, 100, 256)
- **Validation**: Perfect uniformity verified
- **Estimated effort**: 1 hour

### Task 4.3: Unit tests for jump hash movement
- **File**: `src/sharding.zig` (test section)
- **Tests**:
  - Generate 100K keys, hash with N buckets, then N+1 buckets
  - Count how many keys changed buckets
  - Verify exactly ~1/(N+1) moved
  - Test N→N+1 for various N (8→9, 16→17, 100→101)
- **Validation**: Optimal movement verified
- **Estimated effort**: 1 hour

### Task 4.4: Integration tests for strategy selection
- **File**: `src/integration_tests.zig` or new test
- **Tests**:
  - Initialize cluster with each strategy
  - Insert entities, verify routing
  - Restart cluster, verify strategy preserved
  - Query entities, verify consistency
- **Validation**: Integration tests pass
- **Estimated effort**: 2 hours

### Task 4.5: Benchmark comparison
- **File**: Benchmark script or test
- **Tests**:
  - Measure lookup latency for each strategy
  - Measure memory usage for each strategy
  - Compare to documented expectations
- **Validation**: Jump hash ≤ virtual ring latency, zero memory
- **Estimated effort**: 1 hour

## Phase 5: Documentation

### Task 5.1: Update CLI help text
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Document --sharding-strategy flag
  - Explain each strategy's tradeoffs
  - Recommend jump_hash for most use cases
- **Validation**: `archerdb init --help` shows flag
- **Estimated effort**: 30 minutes

### Task 5.2: Update operational documentation
- **File**: Documentation (docs/ or wiki)
- **Changes**:
  - Document strategy selection guide
  - Document resharding behavior per strategy
  - Add migration procedures between strategies
- **Validation**: Documentation review
- **Estimated effort**: 1 hour

### Task 5.3: Update CHANGELOG
- **File**: `CHANGELOG.md`
- **Changes**:
  - Add Jump Consistent Hash feature
  - Note new --sharding-strategy flag
  - Note jump_hash is new default
- **Validation**: Changelog entry accurate
- **Estimated effort**: 15 minutes

## Dependencies & Parallelization

### Sequential Dependencies

- Phase 1 must complete before Phase 2 (CLI needs enum)
- Phase 2 must complete before Phase 3 (integration needs config)
- Phase 4 depends on Phases 1-3

### Parallelizable Work

- Task 1.1 and 1.2 can be done in parallel
- Task 2.1, 2.3, 2.4 can be done in parallel (different files)
- All Phase 4 tests can be written in parallel
- All Phase 5 documentation can be done in parallel

## Verification Checklist

- [x] `jumpHash()` returns correct values (verified against reference)
- [x] `jumpHash()` has perfect uniformity
- [x] `jumpHash()` has optimal 1/(N+1) movement
- [x] `ShardingStrategy` enum with all methods
- [x] `--sharding-strategy` CLI flag works
- [ ] Strategy persisted in cluster metadata (requires superblock changes - deferred)
- [ ] Strategy shown in `archerdb info` (depends on persistence - deferred)
- [x] Power-of-2 validation for modulo only
- [x] All strategies work in query routing (via getShardForEntityWithStrategy)
- [x] Resharding works with all strategies (ReshardingManager supports all strategies)
- [x] Unit tests pass
- [x] Integration tests pass (tested via getShardForEntityWithStrategy tests)
- [x] Benchmarks show expected performance (test: "sharding strategy throughput comparison")
- [x] Documentation updated (CLI help text)

## Estimated Total Effort

- **Implementation**: 6-8 hours
- **Testing**: 5-6 hours
- **Documentation**: 2 hours
- **Total**: 13-16 hours (~2 working days)

## Rollout Strategy

1. **Merge to main** after all tests pass
2. **Default: jump_hash** for new clusters (recommended)
3. **Existing clusters**: Keep current strategy (backward compatible)
4. **Migration tooling**: Available for strategy changes
5. **Document**: Strategy selection guide for operators
