# Design: Online Index Rehash

## Context

ArcherDB's RAM index uses open addressing with linear probing. Hash table resizing traditionally requires copying all entries to a new table - a blocking operation. Online rehash must maintain availability during this process.

## Goals / Non-Goals

### Goals

1. **Zero downtime**: Queries continue during resize
2. **Bounded memory**: At most 2x during resize
3. **Incremental**: Small batches, not big-bang
4. **Observable**: Progress metrics and logging

### Non-Goals

1. **Shrinking**: Only grow (simplifies invariants)
2. **Automatic trigger**: Manual only (predictable ops)
3. **Zero overhead**: Some latency impact acceptable

## Decisions

### Decision 1: Double-Buffer with Lazy Migration

**Choice**: Maintain two tables during resize; migrate lazily on access + background sweeper.

**Rationale**:
- Reads always succeed (check both tables)
- Writes go to new table (migrate on write if needed)
- Background thread handles remaining entries
- No single blocking operation

**Implementation**:
```zig
pub const ResizableRAMIndex = struct {
    /// Active table (queries go here first)
    active: []IndexEntry,
    active_capacity: u64,

    /// Old table during resize (null when not resizing)
    old: ?[]IndexEntry,
    old_capacity: u64,

    /// Resize progress (entries migrated / old_capacity)
    resize_progress: std.atomic.Value(u64),

    /// State machine
    state: enum { normal, resizing, completing },
};
```

### Decision 2: Incremental Migration Strategy

**Choice**: Migrate entries in batches during:
1. Every upsert (migrate entry being touched)
2. Background sweep (low-priority thread)
3. Lookup miss in new table (check old, migrate if found)

**Rationale**:
- Hot entries migrate quickly (accessed frequently)
- Cold entries migrate in background
- No single long-running operation

**Implementation**:
```zig
pub fn lookup(self: *Self, entity_id: u128) ?*const IndexEntry {
    // 1. Try active table first
    if (self.lookupIn(self.active, entity_id)) |entry| {
        return entry;
    }

    // 2. If resizing, check old table
    if (self.old) |old_table| {
        if (self.lookupIn(old_table, entity_id)) |old_entry| {
            // Migrate to new table
            self.migrateEntry(old_entry.*);
            // Return from new table
            return self.lookupIn(self.active, entity_id);
        }
    }

    return null;
}

pub fn upsert(self: *Self, entry: IndexEntry) !void {
    // Always insert into active table
    try self.upsertInto(self.active, entry);

    // If resizing, mark old slot as migrated
    if (self.old) |old_table| {
        self.markMigrated(old_table, entry.entity_id);
    }
}
```

### Decision 3: Background Sweeper Thread

**Choice**: Dedicated thread migrates entries during idle periods.

**Rationale**:
- Doesn't block query path
- Completes resize even if traffic is read-heavy
- Rate-limited to avoid impact

**Implementation**:
```zig
fn backgroundSweeper(self: *Self) void {
    const batch_size: usize = 1000;
    const sleep_between_batches_ns: u64 = 1_000_000; // 1ms

    while (self.state == .resizing) {
        var migrated: usize = 0;

        // Scan old table for unmigrated entries
        for (self.old.?[self.sweep_cursor..]) |*entry| {
            if (!entry.is_empty() and !self.isMigrated(entry)) {
                self.migrateEntry(entry.*);
                migrated += 1;
                if (migrated >= batch_size) break;
            }
            self.sweep_cursor += 1;
        }

        if (self.sweep_cursor >= self.old_capacity) {
            self.completeResize();
            return;
        }

        std.time.sleep(sleep_between_batches_ns);
    }
}
```

### Decision 4: Resize Initiation Protocol

**Choice**: Explicit CLI command with safety checks.

**Rationale**:
- Predictable for operators
- Pre-checks prevent failures mid-resize
- Clear ownership of the operation

**Implementation**:
```bash
# Check if resize is safe
archerdb index resize --check --new-capacity=2000000000

# Output:
# Current capacity: 1,000,000,000
# New capacity:     2,000,000,000
# Current entries:    750,000,000 (75% load)
# Memory required:    ~128GB (current ~64GB)
# Available RAM:      256GB
# Status: SAFE TO PROCEED

# Initiate resize
archerdb index resize --new-capacity=2000000000
```

## Architecture

### State Machine

```
                    ┌──────────────┐
      resize cmd    │              │
    ───────────────>│    NORMAL    │
                    │              │
                    └──────┬───────┘
                           │ allocate new table
                           │ start sweeper
                           ▼
                    ┌──────────────┐
                    │              │
                    │   RESIZING   │<──┐
                    │              │   │ batch complete
                    └──────┬───────┘───┘
                           │ all entries migrated
                           │ free old table
                           ▼
                    ┌──────────────┐
      ready for     │              │
      new resize    │   NORMAL     │
    <───────────────│              │
                    └──────────────┘
```

### Memory Layout During Resize

```
                    BEFORE RESIZE              DURING RESIZE
                    ┌────────────────┐         ┌────────────────┐
                    │                │         │                │
                    │  Active Table  │         │  Active Table  │ (NEW, 2x size)
                    │  (1B slots)    │         │  (2B slots)    │
                    │                │         │                │
                    └────────────────┘         ├────────────────┤
                                               │                │
                                               │   Old Table    │ (being drained)
                                               │  (1B slots)    │
                                               │                │
                                               └────────────────┘

                    ~64GB RAM                  ~192GB RAM peak
                                               (drops to ~128GB after complete)
```

### Query Path During Resize

```
                          LOOKUP(entity_id)
                                │
                                ▼
                    ┌───────────────────────┐
                    │ Search Active Table   │
                    └───────────┬───────────┘
                                │
                        ┌───────┴───────┐
                        │               │
                      found          not found
                        │               │
                        ▼               ▼
                    ┌───────┐   ┌───────────────────────┐
                    │Return │   │ Resizing?             │
                    │Entry  │   └───────────┬───────────┘
                    └───────┘               │
                                    ┌───────┴───────┐
                                    │               │
                                   yes              no
                                    │               │
                                    ▼               ▼
                    ┌───────────────────────┐   ┌───────┐
                    │ Search Old Table      │   │Return │
                    └───────────┬───────────┘   │ NULL  │
                                │               └───────┘
                        ┌───────┴───────┐
                        │               │
                      found          not found
                        │               │
                        ▼               ▼
                    ┌───────────────┐   ┌───────┐
                    │Migrate + Return│   │Return │
                    └───────────────┘   │ NULL  │
                                        └───────┘
```

## Configuration

### CLI Commands

```bash
# Check resize feasibility
archerdb index resize --check --new-capacity=<N>

# Start resize
archerdb index resize --new-capacity=<N>

# Monitor progress
archerdb index resize --status

# Abort resize (if issues)
archerdb index resize --abort
```

### Tuning Parameters

```zig
pub const RehashConfig = struct {
    /// Entries migrated per background batch
    batch_size: usize = 1000,

    /// Sleep between batches (microseconds)
    batch_interval_us: u64 = 1000,

    /// Max percentage of CPU for background migration
    max_background_cpu_percent: u8 = 10,
};
```

## Trade-Offs

### Lazy vs Eager Migration

| Aspect | Lazy (Chosen) | Eager |
|--------|---------------|-------|
| Query latency during resize | Slightly higher | Much higher |
| Time to complete | Variable | Predictable |
| Memory peak | 2x | 2x |
| Implementation complexity | Higher | Lower |

**Chose lazy**: Query latency is critical for ArcherDB's use cases.

## Validation Plan

### Unit Tests

1. **Resize state machine**: All transitions correct
2. **Concurrent access**: No races during resize
3. **Progress tracking**: Metrics accurate

### Integration Tests

1. **Resize under load**: Queries continue during resize
2. **Crash recovery**: Resume after restart
3. **Abort handling**: Clean rollback

### Performance Tests

1. **Latency impact**: Measure P99 during resize
2. **Throughput impact**: Measure QPS during resize
3. **Completion time**: Time to migrate N entries
