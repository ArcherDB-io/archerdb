# Hybrid Memory

## ADDED Requirements

### Requirement: Memory-Mapped Index Fallback (Optional)
The system SHALL support optional memory-mapping of index data.

#### Scenario: Memory Constraints
- **WHEN** system RAM is insufficient for full index
- **THEN** the system MAY optionally fallback to memory-mapped files
- **AND** this behavior SHALL be configurable via `memory_mapped_index_enabled` flag

### Requirement: Observability Integration for Index Health
The system SHALL expose metrics for index health monitoring.

#### Scenario: Index Health Metrics
- **WHEN** the index is operating
- **THEN** the system SHALL expose the following metrics:
  - `archerdb_index_entries_total`
  - `archerdb_index_memory_bytes`
  - `archerdb_index_lookup_latency_seconds`

## Implementation Status

| Requirement | Status | Implementation |
|-------------|--------|----------------|
| Memory-Mapped Index Fallback (Optional) | IMPLEMENTED | `src/ram_index.zig` - mmap-backed init; `src/geo_state_machine.zig` - OOM fallback; `src/archerdb/cli.zig` - config flag |
| Observability Integration for Index Health | IMPLEMENTED | `src/archerdb/metrics.zig`, `src/archerdb/main.zig`, `src/ram_index.zig` |
