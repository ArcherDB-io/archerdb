# Implementation Tasks: Compact Index Entry Format

## Phase 1: Entry Types

### Task 1.1: Define CompactIndexEntry struct
- **File**: `src/ram_index.zig`
- **Changes**:
  - Add `CompactIndexEntry` extern struct (32 bytes)
  - Add comptime size/alignment assertions
  - Implement `is_empty`, `is_tombstone`, `timestamp` methods
- **Validation**: Comptime assertions pass
- **Estimated effort**: 30 minutes

### Task 1.2: Create IndexEntryInterface
- **File**: `src/ram_index.zig`
- **Changes**:
  - Define common interface for both entry types
  - Ensure method signatures match
  - Add type-level documentation
- **Validation**: Both types satisfy interface
- **Estimated effort**: 30 minutes

## Phase 2: Generic Index

### Task 2.1: Refactor RAMIndex to generic
- **File**: `src/ram_index.zig`
- **Changes**:
  - Convert `RAMIndex` to `GenericRAMIndex(Entry)`
  - Parameterize all methods on entry type
  - Create type aliases: `RAMIndex`, `CompactRAMIndex`
- **Validation**: Existing tests pass with `RAMIndex` alias
- **Estimated effort**: 2 hours

### Task 2.2: Update all RAMIndex usages
- **Files**: All files using `RAMIndex`
- **Changes**:
  - Update imports if needed
  - Verify type inference works
- **Validation**: Full build succeeds
- **Estimated effort**: 1 hour

## Phase 3: Build Configuration

### Task 3.1: Add build option
- **File**: `build.zig`
- **Changes**:
  - Add `index-format` option (standard/compact)
  - Pass option to source via build options
- **Validation**: `zig build --help` shows option
- **Estimated effort**: 30 minutes

### Task 3.2: Conditional type selection
- **File**: `src/ram_index.zig` or new config file
- **Changes**:
  - Select `ActiveIndexEntry` based on build option
  - Export `ActiveRAMIndex` type
  - Add `index_format_name` constant
- **Validation**: Both formats compile
- **Estimated effort**: 30 minutes

### Task 3.3: Update dependent modules
- **Files**: Modules that instantiate RAMIndex
- **Changes**:
  - Use `ActiveRAMIndex` instead of hardcoded type
  - Handle any type-specific logic
- **Validation**: Both formats build and pass tests
- **Estimated effort**: 1 hour

## Phase 4: Metrics

### Task 4.1: Add format-aware metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Add `archerdb_index_entry_size_bytes` gauge
  - Add `archerdb_index_format` label
  - Update memory metrics to reflect actual entry size
- **Validation**: Metrics visible in /metrics
- **Estimated effort**: 30 minutes

### Task 4.2: Memory calculation updates
- **File**: `src/ram_index.zig`
- **Changes**:
  - Use `@sizeOf(Entry)` for memory calculations
  - Update capacity estimation functions
  - Fix any hardcoded 64-byte assumptions
- **Validation**: Memory metrics accurate for both formats
- **Estimated effort**: 30 minutes

## Phase 5: Testing

### Task 5.1: Unit tests for CompactIndexEntry
- **File**: `src/ram_index.zig` (test section)
- **Tests**:
  - Size and alignment assertions
  - Method correctness (is_empty, is_tombstone, timestamp)
  - Empty entry sentinel value
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 5.2: Unit tests for GenericRAMIndex
- **File**: `src/ram_index.zig` (test section)
- **Tests**:
  - Instantiate with both entry types
  - Lookup/upsert identical behavior
  - Stats tracking correct
- **Validation**: All tests pass
- **Estimated effort**: 1 hour

### Task 5.3: Performance comparison test
- **File**: `src/ram_index.zig` (test section) or benchmark
- **Tests**:
  - Throughput: standard vs compact
  - Latency percentiles comparison
  - Memory usage verification
- **Validation**: Compact within 5% of standard throughput
- **Estimated effort**: 2 hours

### Task 5.4: Integration test
- **File**: Integration test suite
- **Tests**:
  - Full query path with compact index
  - TTL behavior without index-level TTL
  - End-to-end correctness
- **Validation**: All integration tests pass
- **Estimated effort**: 1 hour

## Phase 6: Documentation

### Task 6.1: Update CLI help
- **File**: CLI help text
- **Changes**:
  - Document `--index-format` build option
  - Explain trade-offs
- **Validation**: Help text accurate
- **Estimated effort**: 15 minutes

### Task 6.2: Add deployment guidance
- **File**: Documentation
- **Changes**:
  - When to use standard vs compact
  - Memory planning guide
  - Performance expectations
- **Validation**: Documentation review
- **Estimated effort**: 30 minutes

## Dependencies

- Phase 2 depends on Phase 1
- Phase 3 depends on Phase 2
- Phase 4-6 can proceed in parallel after Phase 3

## Estimated Total Effort

- **Entry Types**: 1 hour
- **Generic Index**: 3 hours
- **Build Configuration**: 2 hours
- **Metrics**: 1 hour
- **Testing**: 5 hours
- **Documentation**: 45 minutes
- **Total**: ~13 hours (~1.5-2 working days)

## Verification Checklist

- [x] `CompactIndexEntry` is exactly 32 bytes
- [x] `GenericRAMIndex` works with both entry types
- [x] Build option selects correct format (`-Dindex-format=compact`)
- [x] Memory metrics reflect actual entry size (entry_size constant)
- [x] Compact format within 5% throughput of standard (test: "throughput: compact format within 5% of standard")
- [x] All existing tests pass with both formats
- [x] Documentation explains trade-offs (code comments)
