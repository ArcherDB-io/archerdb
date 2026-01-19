# Implementation Tasks: Online Index Rehash

## Phase 1: Data Structures

### Task 1.1: Add resize state to RAMIndex
- **File**: `src/ram_index.zig`
- **Changes**:
  - Add `old` table pointer (optional)
  - Add `state` enum (normal, resizing, completing)
  - Add `resize_progress` atomic counter
  - Add `sweep_cursor` for background thread
- **Validation**: Compiles, existing tests pass
- **Estimated effort**: 1 hour

### Task 1.2: Add migration tracking
- **File**: `src/ram_index.zig`
- **Changes**:
  - Add bitmap or marker for migrated entries
  - Implement `isMigrated()` and `markMigrated()`
  - Ensure thread-safe access
- **Validation**: Unit tests for migration tracking
- **Estimated effort**: 1 hour

## Phase 2: Core Operations

### Task 2.1: Modify lookup for dual-table
- **File**: `src/ram_index.zig`
- **Changes**:
  - Check active table first
  - If resizing and not found, check old table
  - Migrate entry if found in old table
  - Return from active table after migration
- **Validation**: Lookup finds entries in both tables
- **Estimated effort**: 1.5 hours

### Task 2.2: Modify upsert for dual-table
- **File**: `src/ram_index.zig`
- **Changes**:
  - Always insert into active table
  - Mark old table entry as migrated if exists
  - Handle tombstones correctly
- **Validation**: Upserts work during resize
- **Estimated effort**: 1.5 hours

### Task 2.3: Implement migrateEntry
- **File**: `src/ram_index.zig`
- **Changes**:
  - Copy entry from old to new table
  - Mark as migrated in old table
  - Update statistics
  - Handle concurrent access
- **Validation**: Entries migrate correctly
- **Estimated effort**: 1 hour

## Phase 3: Background Sweeper

### Task 3.1: Implement sweeper thread
- **File**: `src/ram_index.zig`
- **Changes**:
  - Background thread function
  - Batch-based migration
  - Rate limiting
  - State transitions
- **Validation**: Sweeper migrates all entries
- **Estimated effort**: 2 hours

### Task 3.2: Add sweeper configuration
- **File**: `src/ram_index.zig`
- **Changes**:
  - `RehashConfig` struct
  - Batch size, interval, CPU limit
  - Runtime adjustment support
- **Validation**: Config affects sweeper behavior
- **Estimated effort**: 30 minutes

### Task 3.3: Implement resize completion
- **File**: `src/ram_index.zig`
- **Changes**:
  - Verify all entries migrated
  - Free old table memory
  - Transition to normal state
  - Update capacity metrics
- **Validation**: Clean completion, memory freed
- **Estimated effort**: 1 hour

## Phase 4: Resize Initiation

### Task 4.1: Implement startResize
- **File**: `src/ram_index.zig`
- **Changes**:
  - Validate new capacity > current
  - Check available memory
  - Allocate new table
  - Start sweeper thread
  - Transition to resizing state
- **Validation**: Resize starts successfully
- **Estimated effort**: 1.5 hours

### Task 4.2: Implement abortResize
- **File**: `src/ram_index.zig`
- **Changes**:
  - Stop sweeper thread
  - Free new table if abort early enough
  - Or complete migration if past threshold
  - Clean state transition
- **Validation**: Abort works at various stages
- **Estimated effort**: 1 hour

### Task 4.3: Implement resize status query
- **File**: `src/ram_index.zig`
- **Changes**:
  - Return current state
  - Progress percentage
  - Estimated time remaining
  - Entries migrated/remaining
- **Validation**: Accurate progress reporting
- **Estimated effort**: 30 minutes

## Phase 5: CLI Integration

### Task 5.1: Add resize subcommand
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Parse `index resize` command
  - Parse `--new-capacity`, `--check`, `--status`, `--abort`
  - Validate capacity values
- **Validation**: CLI parsing works
- **Estimated effort**: 1 hour

### Task 5.2: Implement resize check
- **File**: `src/archerdb/cli.zig` or handler
- **Changes**:
  - Calculate memory requirements
  - Check available RAM
  - Report safety status
  - Show current vs new capacity
- **Validation**: Accurate safety check
- **Estimated effort**: 1 hour

### Task 5.3: Wire CLI to resize operations
- **File**: `src/archerdb/main.zig` or handler
- **Changes**:
  - Connect CLI commands to RAMIndex methods
  - Handle errors gracefully
  - Output progress updates
- **Validation**: End-to-end resize via CLI
- **Estimated effort**: 1 hour

## Phase 6: Metrics & Observability

### Task 6.1: Add resize metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - `archerdb_index_resize_state` gauge
  - `archerdb_index_resize_progress` gauge
  - `archerdb_index_resize_entries_migrated_total` counter
  - `archerdb_index_resize_duration_seconds` gauge
- **Validation**: Metrics visible during resize
- **Estimated effort**: 30 minutes

### Task 6.2: Add resize logging
- **File**: `src/ram_index.zig`
- **Changes**:
  - Log resize start/complete/abort
  - Log progress milestones (25%, 50%, 75%)
  - Log any errors or warnings
- **Validation**: Clear log trail
- **Estimated effort**: 30 minutes

## Phase 7: Testing

### Task 7.1: Unit tests for resize operations
- **File**: `src/ram_index.zig` (test section)
- **Tests**:
  - Start resize with valid capacity
  - Reject resize with invalid capacity
  - Lookup during resize finds all entries
  - Upsert during resize works correctly
- **Validation**: All tests pass
- **Estimated effort**: 2 hours

### Task 7.2: Concurrency tests
- **File**: `src/ram_index.zig` (test section)
- **Tests**:
  - Concurrent lookups during resize
  - Concurrent upserts during resize
  - No data races (ThreadSanitizer)
- **Validation**: No races detected
- **Estimated effort**: 2 hours

### Task 7.3: Integration tests
- **File**: Integration test suite
- **Tests**:
  - CLI-driven resize
  - Resize under production-like load
  - Abort and resume scenarios
- **Validation**: All scenarios work
- **Estimated effort**: 2 hours

### Task 7.4: Performance tests
- **File**: Benchmark suite
- **Tests**:
  - Latency impact during resize
  - Throughput impact during resize
  - Time to complete various resize sizes
- **Validation**: <10% latency impact
- **Estimated effort**: 2 hours

## Dependencies

- Phase 2 depends on Phase 1
- Phase 3 depends on Phase 2
- Phase 4 depends on Phase 3
- Phases 5, 6, 7 can proceed in parallel after Phase 4

## Estimated Total Effort

- **Data Structures**: 2 hours
- **Core Operations**: 4 hours
- **Background Sweeper**: 3.5 hours
- **Resize Initiation**: 3 hours
- **CLI Integration**: 3 hours
- **Metrics & Observability**: 1 hour
- **Testing**: 8 hours
- **Total**: ~25 hours (~3-4 working days)

## Verification Checklist

- [x] Resize starts without blocking queries (startResize in src/ram_index.zig)
- [x] Lookup finds entries in both tables during resize (dual-table lookup in src/ram_index.zig)
- [x] Upsert works correctly during resize (writes to new table in src/ram_index.zig)
- [x] Background sweeper completes migration (migrateEntryBatch in src/ram_index.zig)
- [x] Resize can be aborted cleanly (abortResize in src/ram_index.zig)
- [x] Progress tracked (getResizeProgress, ResizeProgress in src/ram_index.zig)
- [x] Metrics track progress accurately (src/archerdb/metrics.zig: index_resize_* metrics, wired to src/ram_index.zig)
- [ ] Latency impact <10% during resize (needs performance testing)
- [ ] No data races in concurrent access (needs ThreadSanitizer testing)
- [x] CLI commands work end-to-end (index resize/stats in cli.zig:854, main.zig:444)
