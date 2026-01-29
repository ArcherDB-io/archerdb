# Phase 3: Data Integrity - Context

**Gathered:** 2026-01-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Verify that data survives crashes, restores correctly, and maintains consistency across failures. This phase validates WAL replay, checkpoint/restore cycles, corruption detection, concurrent write safety, and backup/restore capabilities. The goal is to ensure the database can be trusted with mission-critical data by proving durability guarantees hold under adverse conditions.

Covers requirements: DATA-01 through DATA-09

</domain>

<decisions>
## Implementation Decisions

### Crash Injection Approach
- **Both deterministic and random crash injection**
  - Deterministic: Test specific critical points (mid-WAL-write, mid-checkpoint, during consensus operations)
  - Random: Crash at random points during operations to find unexpected edge cases
- **Crash mechanisms to test:**
  - Process kill (SIGKILL) - most common crash scenario
  - Power loss simulation - validates fsync and durability guarantees
  - Panic/assertion failure - validates recovery from internal errors
  - Follow TigerBeetle's crash testing patterns (whatever they test for)
- **Coverage: Multiple timing variations**
  - Test crashes at beginning, middle, and end of each operation type
  - Thorough validation across operation lifecycle

### Corruption Detection Strategy
- **Corruption types to test:**
  - Single-bit flips - catches checksum failures
  - Block-level corruption - tests recovery mechanisms
  - Partial write simulation (torn pages) - validates atomic write guarantees
  - Follow TigerBeetle's corruption testing patterns
- **Corruption injection locations:**
  - WAL segments - tests recovery from corrupted replay
  - Data files - tests checksum detection on reads
  - Metadata/headers (superblocks) - tests bootstrap recovery
  - Follow TigerBeetle's corruption injection points
- **Corruption scale: Both targeted and cascade scenarios**
  - Single corruption events to isolate detection logic
  - Multiple corruption events (cascade failures) to stress test recovery

### Validation Depth
- **State verification: Byte-for-byte comparison**
  - Compare entire data files after WAL replay
  - Strongest guarantee that exact state was restored
- **Checkpoint/restore verification covers:**
  - All entity data - every entity with all attributes
  - Index integrity - spatial and other indexes return same results
  - Metadata preservation - timestamps, TTLs, internal state
  - Follow TigerBeetle's checkpoint verification patterns
- **Verification scope: Include internal state**
  - Verify LSM tree structure, WAL segments, internal consistency
  - Not just observable behavior - catches subtle implementation bugs
- **Validation strictness: Zero tolerance**
  - Any validation failure is a bug
  - No false positives from implementation details are acceptable

### Test Data Characteristics
- **Data size ranges:**
  - Small datasets (hundreds) - fast iteration, basic correctness
  - Medium datasets (thousands to tens of thousands) - realistic workloads
  - Large datasets (millions) - stress durability and performance boundaries
- **Data patterns:**
  - Sequential IDs/locations - easy to verify, catches basic issues
  - Random distribution - tests real-world scenarios
  - Adversarial patterns (clustered, hash collisions) - finds edge cases
  - Follow TigerBeetle's test data patterns
- **Concurrency patterns: Both realistic and stress-test**
  - Realistic patterns for smoke tests (model actual client behavior)
  - Stress test patterns for finding bugs (high contention, rapid updates)
- **Edge cases to cover:**
  - Empty state transitions (crash/restore with no data, single entity)
  - Boundary values (max entity size, coordinate extremes, TTL edge cases)
  - Operation sequences (insert-delete-insert same ID, rapid updates, interleaved ops)
  - Follow TigerBeetle's edge case coverage

### Claude's Discretion
- Power loss simulation approach (kernel-level vs file system simulation) - choose based on TigerBeetle's patterns and test infrastructure capabilities
- Response to detected corruption (fail fast vs recovery attempts) - align with TigerBeetle's corruption handling philosophy
- Acceptable false-positive rate implementation - guided by zero-tolerance requirement
- Verification level per test type - determine appropriate depth based on what each test validates

</decisions>

<specifics>
## Specific Ideas

- **Follow TigerBeetle's patterns** - User emphasized repeatedly to align with whatever TigerBeetle is testing for crash injection, corruption detection, test data patterns, and edge cases
- Validation approach prioritizes strongest guarantees (byte-for-byte comparison, zero tolerance)
- Comprehensive coverage across all dimensions: crash types, corruption types, data sizes, patterns

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 03-data-integrity*
*Context gathered: 2026-01-29*
