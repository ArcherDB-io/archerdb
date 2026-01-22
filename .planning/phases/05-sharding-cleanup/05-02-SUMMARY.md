# Phase 5 Plan 2: Deprecated Flag & TODO Cleanup Summary

## One-liner
Removed deprecated --aof flag, resolved all TODOs in VSR/storage/LSM production code, marked doc TODOs for Phase 9.

## What Was Built

### Task 1: Remove deprecated --aof flag (CLEAN-01)
- **Removed from cli.zig:**
  - Deleted `aof: bool = false` option definition
  - Removed mutual exclusivity check with --aof-file
  - Removed deprecated warning log message
  - Updated documentation to reference --aof-file only
- **Updated main.zig:**
  - Changed warning message from "--aof" to "--aof-file"
- **Result:** Users must use `--aof-file=<path>.aof` syntax going forward

### Task 2a: Resolve VSR TODOs
- **replica.zig (16 TODOs resolved):**
  - Documented ping_timeout purposes (MessageBus handshaking, leapfrogging, view change decisions)
  - Converted performance TODOs to Enhancement: comments
  - Documented known issue about primary standdown during partitions
  - Marked buggify/optimization TODOs appropriately
- **superblock.zig (5 TODOs resolved):**
  - Renamed sync_view to sync_view_reserved (deprecated field)
  - Documented u16 alignment for copy field
  - Documented grandparent_checkpoint_id purpose
  - Documented view_change naming quirk
- **message_header.zig (3 TODOs resolved):**
  - Documented checksum padding fields (Zig u256 extern struct limitation)
  - Marked timestamp bulk-import as Enhancement
- **vopr.zig (6 TODOs resolved):**
  - Converted fuzzer TODOs to TestEnhancement: comments
  - Documented context assignment requirement

### Task 2b: Resolve Storage/LSM TODOs
- **storage.zig (7 TODOs resolved):**
  - Documented partial sector read behavior
  - Explained path resolution approach
  - Documented EIO error handling strategy
  - Documented AIMD backoff recovery
  - Explained panic behavior for write errors
- **manifest_log.zig (6 TODOs resolved):**
  - Marked memory optimization as Enhancement
  - Documented RingBuffer alignment handling
  - Documented block reservation validation
  - Documented manifest compaction timing
- **scan_builder.zig (1 TODO resolved):**
  - Documented Orthogonal Grooves as Enhancement

### Task 3: Final Cleanup
- Marked CLI documentation TODO as DocTODO (deferred to Phase 9)
- Verified no FIXME/XXX/HACK/BUG markers in production code
- Build passes, all tests pass

## Deviations from Plan

None - plan executed exactly as written.

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Use Enhancement: prefix | Per CONTEXT.md, future features not blocking correctness are marked as Enhancement: | Clearer distinction between bugs and wishlist items |
| Use Note: prefix | Explanatory comments that document current behavior | Better code understanding |
| Use TestEnhancement: prefix | VOPR/fuzz improvements that don't affect correctness | Test infrastructure clarity |
| DocTODO: for docs | Per CONTEXT.md, documentation deferred to Phase 9 | Consistent deferred handling |

## Verification Results

| Check | Status | Details |
|-------|--------|---------|
| Build passes | PASS | `./zig/zig build` succeeds |
| --aof flag removed | PASS | No references to deprecated flag |
| VSR TODOs | PASS | 0 TODOs in replica, superblock, message_header |
| Storage/LSM TODOs | PASS | 0 TODOs in storage, manifest_log, scan_builder |
| FIXME/XXX/HACK/BUG | PASS | No markers in production code |

## Files Changed

### Created
None

### Modified
- `src/archerdb/cli.zig` - Removed --aof flag, marked doc TODO
- `src/archerdb/main.zig` - Updated warning message
- `src/vsr/replica.zig` - Resolved 16 TODOs
- `src/vsr/superblock.zig` - Resolved 5 TODOs, renamed sync_view field
- `src/vsr/message_header.zig` - Resolved 3 TODOs
- `src/vopr.zig` - Resolved 6 TODOs
- `src/storage.zig` - Resolved 7 TODOs
- `src/lsm/manifest_log.zig` - Resolved 6 TODOs
- `src/lsm/scan_builder.zig` - Resolved 1 TODO

## Commits

| Hash | Message |
|------|---------|
| a17baac | feat(05-02): remove deprecated --aof flag |
| 6e90635 | chore(05-02): resolve TODOs in VSR code (replica, superblock, message_header, vopr) |
| 2962188 | chore(05-02): resolve TODOs in Storage and LSM code |
| 29872f4 | chore(05-02): defer documentation TODO to Phase 9 |

## Performance

- Duration: ~25 minutes
- Tasks: 4/4 complete
- Commits: 4

## Next Phase Readiness

Phase 5 Plan 2 complete. Ready for Plan 3 (if applicable) or Phase 5 verification.

### Remaining Work
- ~70 TODOs remain in codebase (outside plan-specified files)
- These are primarily:
  - Zig language limitations (cannot be fixed until Zig evolves)
  - Test/fuzz infrastructure (acceptable per CONTEXT.md)
  - Future enhancements in lower-priority code paths
