# Hybrid Memory - Compact Index Entry Format

## ADDED Requirements

### Requirement: Compact Index Entry Format

The system SHALL support a memory-optimized 32-byte index entry format for constrained environments.

#### Scenario: CompactIndexEntry struct definition

- **WHEN** building with compact index format enabled
- **THEN** the system SHALL use `CompactIndexEntry`:
  ```zig
  pub const CompactIndexEntry = extern struct {
      entity_id: u128 = 0,   // 16 bytes - lookup key
      latest_id: u128 = 0,   // 16 bytes - composite ID
      // Total: 32 bytes (no TTL, no padding)
  };
  ```
- **AND** `@sizeOf(CompactIndexEntry)` SHALL equal exactly 32 bytes
- **AND** `@alignOf(CompactIndexEntry)` SHALL be at least 16 bytes

#### Scenario: CompactIndexEntry methods

- **WHEN** using CompactIndexEntry
- **THEN** it SHALL implement:
  - `is_empty()` - Returns true if entity_id == 0
  - `is_tombstone()` - Returns true if entity_id != 0 and latest_id == 0
  - `timestamp()` - Returns lower 64 bits of latest_id
- **AND** behavior SHALL be identical to IndexEntry methods

#### Scenario: Memory savings

- **WHEN** using compact format
- **THEN** memory requirements SHALL be:
  - 32 bytes per entry (vs 64 bytes standard)
  - ~46GB for 1B entities at 70% load factor (vs ~92GB)
  - 50% reduction in RAM requirements

### Requirement: Build-Time Format Selection

The system SHALL support selecting index entry format at build time.

#### Scenario: Build option

- **WHEN** building ArcherDB
- **THEN** the operator MAY specify:
  ```bash
  zig build -Dindex-format=compact
  ```
- **AND** default SHALL be `standard` (64-byte entries)
- **AND** compact mode SHALL use 32-byte entries

#### Scenario: Compile-time type selection

- **WHEN** index format is selected
- **THEN** the system SHALL define:
  ```zig
  pub const ActiveIndexEntry = if (build_options.index_format == .compact)
      CompactIndexEntry
  else
      IndexEntry;

  pub const ActiveRAMIndex = GenericRAMIndex(ActiveIndexEntry);
  ```
- **AND** all index operations SHALL use `ActiveRAMIndex`

#### Scenario: Format detection at runtime

- **WHEN** querying index configuration
- **THEN** the system SHALL expose:
  ```zig
  pub const index_entry_size: u32 = @sizeOf(ActiveIndexEntry);
  pub const index_format_name: []const u8 =
      if (index_entry_size == 64) "standard" else "compact";
  ```

### Requirement: Generic RAM Index

The system SHALL implement a generic RAM index parameterized on entry type.

#### Scenario: Generic implementation

- **WHEN** implementing RAMIndex
- **THEN** it SHALL be generic over entry type:
  ```zig
  pub fn GenericRAMIndex(comptime Entry: type) type {
      return struct {
          entries: []Entry,
          capacity: u64,
          stats: IndexStats,
          // ... methods
      };
  }
  ```
- **AND** all operations SHALL work identically for both entry types

#### Scenario: Type aliases

- **WHEN** using the index
- **THEN** the system SHALL provide:
  ```zig
  pub const RAMIndex = GenericRAMIndex(IndexEntry);
  pub const CompactRAMIndex = GenericRAMIndex(CompactIndexEntry);
  ```

### Requirement: Compact Format Limitations

The system SHALL document compact format trade-offs.

#### Scenario: No index-level TTL

- **WHEN** using compact format
- **THEN** index entries SHALL NOT store TTL
- **AND** TTL expiration SHALL be checked at query time from GeoEvent
- **AND** this MAY result in slightly slower TTL checks

#### Scenario: No reserved space

- **WHEN** using compact format
- **THEN** there SHALL be no reserved bytes for future fields
- **AND** future extensions MAY require format migration

#### Scenario: Cache performance trade-off

- **WHEN** using compact format
- **THEN** entries MAY span cache line boundaries
- **AND** two entries fit per 64-byte cache line
- **AND** random access performance MAY be 0-5% slower
- **AND** sequential scans MAY be faster due to better cache utilization

### Requirement: Compact Format Metrics

The system SHALL expose metrics for index format configuration.

#### Scenario: Entry size metric

- **WHEN** exposing metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_index_entry_size_bytes Size of each index entry
  # TYPE archerdb_index_entry_size_bytes gauge
  archerdb_index_entry_size_bytes 32
  ```

#### Scenario: Format label

- **WHEN** exposing index metrics
- **THEN** they MAY include format label:
  ```
  archerdb_index_memory_bytes{format="compact"} 46000000000
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Compact Index Entry Format | IMPLEMENTED | RAM index entry optimization |
| Build-Time Format Selection | IMPLEMENTED | RAM index entry optimization |
| Generic RAM Index | IMPLEMENTED | RAM index entry optimization |
| Compact Format Limitations | IMPLEMENTED | RAM index entry optimization |
| Compact Format Metrics | IMPLEMENTED | RAM index entry optimization |

## Related Specifications

- See base `hybrid-memory/spec.md` for standard IndexEntry
- See `configuration/spec.md` for build options
- See `observability/spec.md` for metrics
