# Architecture Research: Performance & Scale

**Project:** ArcherDB Performance & Scale Milestone
**Researched:** 2026-01-24
**Mode:** Architecture dimension for performance optimization

## Current Architecture Overview

ArcherDB is a 148K LOC distributed geospatial database built in Zig 0.14.1 with the following core components:

### Consensus Layer (VSR)
- **Location:** `src/vsr/replica.zig`, `src/vsr/journal.zig`
- **Pattern:** Viewstamped Replication with leader-based consensus
- **Key constants:** `replicas_max=6`, `standbys_max=6`, `pipeline_prepare_queue_max=8`
- **WAL:** Circular buffer with `journal_slot_count` entries (configurable, default 1024)
- **Checkpoint:** Every `vsr_checkpoint_ops` commits (derived from journal sizing)

### Storage Layer (LSM-tree)
- **Location:** `src/lsm/tree.zig`, `src/lsm/compaction.zig`, `src/lsm/manifest.zig`
- **Pattern:** Log-Structured Merge-tree with tiered compaction
- **Key constants:**
  - `lsm_levels=7` (enterprise), `lsm_growth_factor=8`
  - `lsm_compaction_ops=32` (ops per memtable flush)
  - `block_size=256KB-512KB`, `lsm_table_coalescing_threshold_percent=40-50%`
- **Tables:** Each level has `growth_factor^(level+1)` tables max
- **Write amp:** ~24x for default config (growth_factor * (levels-1) / 2)

### Indexing Layer
- **RAM Index:** `src/ram_index.zig` - O(1) entity lookup
  - 64-byte IndexEntry (cache-line aligned) or 32-byte CompactIndexEntry
  - Open addressing with linear probing, `target_load_factor=0.70`
  - Online rehash support (dual-table approach during resize)
- **S2 Index:** `src/s2_index.zig` - Spatial queries via S2 cell covering
  - Cell ranges for LSM tree scanning
  - Two-phase filtering: coarse (S2 coverage) + fine (Haversine/polygon)

### Grid/Block Cache
- **Location:** `src/vsr/grid.zig`
- **Pattern:** Set-associative cache (CLOCK eviction)
- **Key constants:** `grid_iops_read_max=32`, `grid_iops_write_max=32`
- **Cache:** `SetAssociativeCacheType` with 16-way associativity, 2-bit CLOCK counters

### Sharding
- **Location:** `src/sharding.zig`, `src/coordinator.zig`
- **Strategies:** `modulo`, `virtual_ring`, `jump_hash` (default), `spatial`
- **Jump hash:** O(log N) compute, O(1) memory, optimal 1/(N+1) movement
- **Coordinator:** Fan-out proxy for multi-shard queries

### Replication
- **Location:** `src/replication.zig`
- **Pattern:** Async log shipping to follower regions
- **Ship queue:** Memory + disk spillover with configurable limits
- **Transport:** Direct TCP or S3 relay

---

## Optimization Integration Points

### 1. VSR Consensus Optimization

**Current bottlenecks:**
- Leader serialization: All writes go through primary
- Prepare quorum collection: `quorum_replication_max=3` network RTTs
- Pipeline depth: `pipeline_prepare_queue_max=8` limits concurrent prepares

**Integration points:**
```
src/vsr/replica.zig:
  - tick() main loop (line 1008+)
  - Prepare message handling
  - CommitStage enum transitions

src/constants.zig:
  - pipeline_prepare_queue_max
  - quorum_replication_max (Flexible Paxos)
  - tick_ms (10ms default)
```

**Optimization vectors:**
- **Batching:** Increase `pipeline_prepare_queue_max` (currently 8, max 128)
- **Flexible Paxos:** Reduce `quorum_replication` below majority, increase `quorum_view_change`
- **Tick frequency:** Reduce `tick_ms` for lower latency (tradeoff: CPU usage)
- **Metrics:** Already present via `archerdb_metrics.Registry.updateVsrMetrics()`

### 2. LSM-tree Compaction Optimization

**Current implementation:**
- Tiered compaction with level-by-level merge
- Paced to run in beats during commit intervals
- Resource pool: `lsm_compaction_iops_read_max=18`, `write_max=17`

**Integration points:**
```
src/lsm/compaction.zig:
  - ResourcePoolType (line 86+)
  - compaction_tables_input_max = 1 + growth_factor
  - TTL expired ratio tracking (EMA with alpha=0.2)

src/lsm/tree.zig:
  - table_mutable / table_immutable flip
  - compaction_op tracking

src/config.zig:
  - lsm_growth_factor (8-10)
  - lsm_compaction_ops (32-64)
  - lsm_table_coalescing_threshold_percent (40-50%)
```

**Optimization vectors:**
- **Leveled compaction:** Current tiered; leveled reduces read amp but increases write amp
- **Parallel compaction:** Multiple trees can compact concurrently (already supported)
- **Compaction scheduling:** Priority-based (hot levels first)
- **TTL-aware compaction:** Track `ttl_expired_ratio` to prioritize expired data cleanup

### 3. RAM Index Memory Optimization

**Current implementation:**
- Fixed capacity at startup (no dynamic resize in production)
- Two entry formats: 64B standard, 32B compact
- Memory for 1B entities: ~91.5GB (standard) or ~45.7GB (compact)

**Integration points:**
```
src/ram_index.zig:
  - IndexEntry / CompactIndexEntry structs
  - max_probe_length=1024
  - target_load_factor=0.70
  - Online rehash (ResizeState)

src/config.zig:
  - index_format: .standard or .compact
```

**Optimization vectors:**
- **Compact format:** 50% memory reduction, lose index-level TTL
- **Online rehash:** Dual-table approach during resize (already implemented)
- **Mmap persistence:** Already supported for faster restart
- **Probe optimization:** SIMD-accelerated hash comparison possible

### 4. Grid Cache Optimization

**Current implementation:**
- Set-associative cache with CLOCK eviction
- 16-way associativity, 2-bit CLOCK counters
- Cache line aligned (64B)

**Integration points:**
```
src/lsm/set_associative_cache.zig:
  - Layout struct: ways=16, tag_bits=8, clock_bits=2
  - value_count_max_multiple for alignment

src/vsr/grid.zig:
  - Grid.Cache using SetAssociativeCacheType
  - read_iops_max, write_iops_max
```

**Optimization vectors:**
- **Cache sizing:** `--cache-grid` CLI flag (recommend 4GB+ for enterprise)
- **Prefetching:** Speculative block reads during scan
- **ARC/LIRS:** More sophisticated eviction (current CLOCK is simpler, fast)
- **Direct I/O bypass:** Hot blocks could skip cache entirely

### 5. Sharding Rebalancing

**Current implementation:**
- Jump hash default (O(1) memory, O(log N) compute)
- Fixed shard count at cluster creation (8-256 shards)
- No online rebalancing

**Integration points:**
```
src/sharding.zig:
  - ShardingStrategy enum
  - jumpHash() function
  - ConsistentHashRing for virtual_ring strategy

src/coordinator.zig:
  - Topology struct
  - getShardForEntity()
  - FanOutResult aggregation
```

**Optimization vectors:**
- **Online resharding:** Add shards without downtime (requires dual-write period)
- **Spatial sharding:** Route by S2 cell for spatial query locality
- **Load-aware routing:** Track shard utilization, rebalance hot shards

### 6. Read Replica Patterns

**Current implementation:**
- Async log shipping to follower regions (`src/replication.zig`)
- No read-from-replica in single-region cluster

**Integration points:**
```
src/replication.zig:
  - RegionRole: primary/follower
  - ShipQueue for WAL entry buffering
  - FollowerApplicator for entry application

src/vsr/replica.zig:
  - ReplicateOptions.star (star topology)
  - Status tracking for replicas
```

**Optimization vectors:**
- **Read replicas:** Route read-only queries to backups
- **Stale reads:** Allow bounded staleness for higher read throughput
- **Witness replicas:** Non-voting replicas that only contribute to consensus

---

## New Components Needed

### 1. Performance Profiling Framework (Priority: HIGH)

**Purpose:** Measure bottlenecks, track regressions
**Location:** `src/testing/profiler.zig` (new)

**Required features:**
- Wall-clock timing per phase (prepare, prefetch, commit)
- CPU cycle counters (RDTSC on x86, CNTVCT on ARM)
- Memory allocation tracking (via CountingAllocator)
- I/O statistics (reads/writes/bytes per operation)

**Integration:**
- Hook into `replica.tick()` main loop
- Add `@import("profiler").begin/end()` to hot paths
- Export via Prometheus metrics (`archerdb_metrics.Registry`)

### 2. Adaptive Compaction Scheduler (Priority: MEDIUM)

**Purpose:** Optimize compaction timing based on workload
**Location:** `src/lsm/compaction_scheduler.zig` (new)

**Required features:**
- Track compaction debt per level
- Priority queue for pending compactions
- Workload classification (read-heavy, write-heavy, mixed)
- Rate limiting to avoid I/O spikes

**Integration:**
- Replace current beat-based pacing in `src/lsm/compaction.zig`
- Add scheduler state to Forest

### 3. Query Cost Estimator (Priority: MEDIUM)

**Purpose:** Predict query execution cost for planning
**Location:** `src/query_estimator.zig` (new)

**Required features:**
- Cardinality estimation for S2 cell ranges
- I/O cost model (blocks to read per level)
- Memory cost model (results buffer sizing)
- Fan-out cost for multi-shard queries

**Integration:**
- Called during query planning in `src/geo_state_machine.zig`
- Feed estimates to coordinator for routing decisions

### 4. Bloom Filter Index (Priority: LOW)

**Purpose:** Reduce negative lookups in LSM tree
**Location:** `src/lsm/bloom_filter.zig` (new)

**Note:** Current architecture uses key-range filtering at index block level (min/max keys per value block). Bloom filters would add value for:
- Secondary indexes with non-monotonic keys
- Point queries with high miss rate

**Integration:**
- Add to `src/lsm/schema.zig` table metadata
- Check bloom before scanning value blocks

---

## Modification Priorities

### Phase 1: Measurement Infrastructure (Week 1-2)

| Component | Change | Risk | Dependencies |
|-----------|--------|------|--------------|
| `src/testing/profiler.zig` | NEW | Low | None |
| `src/archerdb/metrics.zig` | Add latency histograms | Low | None |
| `src/vsr/replica.zig` | Add timing hooks | Low | Profiler |

**Rationale:** Cannot optimize without measurement. Start here.

### Phase 2: LSM Tuning (Week 3-4)

| Component | Change | Risk | Dependencies |
|-----------|--------|------|--------------|
| `src/config.zig` | Tunable compaction params | Low | None |
| `src/lsm/compaction.zig` | Parallel compaction | Medium | Phase 1 metrics |
| `src/constants.zig` | Document enterprise presets | Low | None |

**Rationale:** LSM compaction directly impacts write throughput. Well-understood optimization space.

### Phase 3: RAM Index Optimization (Week 5-6)

| Component | Change | Risk | Dependencies |
|-----------|--------|------|--------------|
| `src/ram_index.zig` | SIMD hash comparison | Medium | None |
| `src/ram_index.zig` | Improve online rehash | Medium | None |
| `src/config.zig` | Auto-select compact format | Low | None |

**Rationale:** RAM index is O(1) but probe length matters at scale. Memory efficiency critical.

### Phase 4: Consensus Tuning (Week 7-8)

| Component | Change | Risk | Dependencies |
|-----------|--------|------|--------------|
| `src/vsr/replica.zig` | Flexible Paxos tuning | High | Extensive testing |
| `src/constants.zig` | Pipeline depth increase | Medium | WAL sizing |
| `src/vsr/journal.zig` | Batch header writes | Medium | Phase 1 metrics |

**Rationale:** VSR changes are highest risk. Defer until other optimizations measured.

### Phase 5: Sharding & Scale (Week 9-10)

| Component | Change | Risk | Dependencies |
|-----------|--------|------|--------------|
| `src/sharding.zig` | Online resharding | High | Dual-write complexity |
| `src/coordinator.zig` | Read replica routing | Medium | Replication stability |
| `src/replication.zig` | Faster follower catch-up | Medium | None |

**Rationale:** Scale-out features. Only pursue after single-node performance optimized.

---

## Suggested Build Order

```
1. Profiling Infrastructure
   |
   +-- Timing hooks in replica tick loop
   +-- Latency histograms in metrics
   +-- Benchmark harness (existing: src/testing/bench.zig)
   |
2. LSM Compaction Tuning
   |
   +-- Document enterprise/mid-tier/lite presets
   +-- Add CLI flags for compaction tuning
   +-- Parallel tree compaction
   |
3. RAM Index Optimization
   |
   +-- SIMD probe comparison (optional)
   +-- Online rehash improvements
   +-- Memory usage reporting
   |
4. Grid Cache Tuning
   |
   +-- Cache hit/miss metrics
   +-- Prefetch during scan
   +-- Sizing recommendations
   |
5. VSR Consensus Tuning
   |
   +-- Flexible Paxos analysis
   +-- Pipeline depth experiments
   +-- Tick frequency tuning
   |
6. Sharding & Scale-out
   |
   +-- Online resharding (breaking change)
   +-- Read replica routing
   +-- Cross-region latency optimization
```

---

## Breaking Changes Considered

### 1. Online Resharding Protocol (HIGH IMPACT)

**What:** Allow adding/removing shards without downtime
**Breaking:** Yes - requires protocol version bump
**Why:** Current shard count fixed at format time

**Migration path:**
1. Add `shard_epoch` to superblock
2. Dual-write period: writes go to old AND new shard
3. Background migration of existing data
4. Cutover: stop dual-write, update clients

**Risk:** Data consistency during migration requires careful coordination

### 2. Compact Index Format Default (MEDIUM IMPACT)

**What:** Default to 32-byte CompactIndexEntry for new clusters
**Breaking:** No - existing clusters unaffected
**Why:** 50% memory reduction for most workloads

**Migration path:**
- New clusters default to compact
- Existing clusters keep current format
- Add `archerdb upgrade-index-format` command for opt-in migration

### 3. Flexible Paxos Quorum (LOW IMPACT)

**What:** Allow `quorum_replication < majority`
**Breaking:** No - config change, same protocol
**Why:** Reduce latency for write-heavy workloads

**Migration path:**
- New config flag: `--quorum-replication=2` (with 5 replicas)
- Require explicit `--quorum-view-change=4` to compensate
- Document tradeoffs in ops guide

---

## Data Flow Changes

### Current Write Path

```
Client -> Any Replica -> Primary (if not primary)
  -> prepare() [assign timestamp]
  -> VSR consensus [prepare_ok quorum]
  -> prefetch() [load LSM data]
  -> commit() [apply to RAM index, LSM mutation]
  -> Reply to client
```

### Optimized Write Path (Proposed)

```
Client -> Coordinator -> Correct Shard Primary (skip redirect)
  -> prepare() [assign timestamp, batch accumulation]
  -> VSR consensus [Flexible Paxos quorum]
  -> prefetch() [speculative, parallel with consensus]
  -> commit() [apply to RAM index, LSM mutation]
  -> Async: replicate to followers
  -> Reply to client (before follower ack)
```

**Changes:**
1. Coordinator routes directly to correct shard (avoid redirect)
2. Prefetch starts during consensus (speculative)
3. Reply before follower ack (at-least-once semantics)
4. Batch accumulation for higher throughput

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| LSM tuning | HIGH | Well-documented in codebase, knobs exposed |
| RAM index | HIGH | Clear implementation, online rehash exists |
| Grid cache | HIGH | Standard set-associative cache pattern |
| VSR consensus | MEDIUM | Flexible Paxos documented but needs validation |
| Sharding | MEDIUM | Jump hash solid, online resharding complex |
| Read replicas | LOW | Async replication exists, read routing not implemented |

---

## Sources

- `/home/g/archerdb/.planning/codebase/ARCHITECTURE.md` - Existing architecture doc
- `/home/g/archerdb/src/constants.zig` - Configuration constants
- `/home/g/archerdb/src/config.zig` - Config presets
- `/home/g/archerdb/docs/lsm-tuning.md` - LSM tuning guide
- `/home/g/archerdb/src/vsr/replica.zig` - VSR implementation
- `/home/g/archerdb/src/lsm/compaction.zig` - Compaction implementation
- `/home/g/archerdb/src/ram_index.zig` - RAM index implementation
- `/home/g/archerdb/src/sharding.zig` - Sharding strategies
- `/home/g/archerdb/src/replication.zig` - Async replication
