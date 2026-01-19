# TTL Retention v2 Spec Deltas

## ADDED Requirements

### Requirement: TTL Extension on Read

The system SHALL support extending entity TTL when the entity is accessed (touch-to-extend pattern).

#### Scenario: TTL extension configuration

- **WHEN** configuring TTL extension
- **THEN** operators SHALL specify:
  ```
  --ttl-extension-enabled=true
  --ttl-extension-amount=86400  # seconds to extend (default: 1 day)
  --ttl-extension-max=2592000   # max total TTL (default: 30 days)
  --ttl-extension-cooldown=3600 # min time between extensions (default: 1 hour)
  ```
- **AND** extension MAY be enabled per entity type

#### Scenario: Automatic TTL extension on read

- **WHEN** an entity with TTL is read (query_uuid, query_radius result)
- **AND** TTL extension is enabled
- **AND** time since last extension > cooldown
- **THEN** the system SHALL:
  - Extend expiration by `ttl_extension_amount`
  - Cap total TTL at `ttl_extension_max`
  - Update entity metadata atomically
  - NOT extend if entity would exceed max TTL
- **AND** extension SHALL be transparent to client

#### Scenario: TTL extension bypass

- **WHEN** a client reads with `no_extend=true` header
- **THEN** the system SHALL:
  - Return entity data normally
  - NOT extend the entity's TTL
  - Log access without extension
- **AND** bypass SHALL be useful for monitoring/debugging

#### Scenario: TTL extension tracking

- **WHEN** TTL extensions occur
- **THEN** each entity SHALL track:
  - `original_ttl`: TTL at insertion
  - `current_ttl`: Current effective TTL
  - `extension_count`: Number of times extended
  - `last_extension_time`: Timestamp of last extension
- **AND** this metadata SHALL be queryable

### Requirement: TTL Extension Policies

The system SHALL support configurable policies for TTL extension behavior.

#### Scenario: Per-entity-type policies

- **WHEN** different entity types need different extension behavior
- **THEN** operators SHALL configure policies:
  ```yaml
  ttl_extension_policies:
    - entity_type_prefix: "vehicle_"
      extension_amount: 3600      # 1 hour
      max_ttl: 86400              # 1 day
      cooldown: 300               # 5 minutes
    - entity_type_prefix: "user_"
      extension_amount: 604800    # 1 week
      max_ttl: 2592000            # 30 days
      cooldown: 86400             # 1 day
    - entity_type_prefix: "*"     # default
      extension_amount: 86400
      max_ttl: 2592000
      cooldown: 3600
  ```
- **AND** prefix matching SHALL use longest-match first

#### Scenario: Extension limits

- **WHEN** TTL extension limits are configured
- **THEN** the system SHALL enforce:
  - `max_extension_count`: Maximum times entity can be extended (default: unlimited)
  - `max_total_ttl`: Absolute maximum TTL regardless of extensions
  - `extension_decay`: Each extension adds less time (e.g., 1d, 12h, 6h, 3h...)
- **AND** limits SHALL be per policy

#### Scenario: Disabled extension for specific entities

- **WHEN** an entity is inserted with `no_auto_extend=true` flag
- **THEN** the system SHALL:
  - Never auto-extend that entity's TTL
  - Respect the original TTL exactly
  - Allow manual TTL update via upsert
- **AND** flag SHALL be stored in entity metadata

### Requirement: TTL Extension Observability

The system SHALL expose metrics for TTL extension behavior.

#### Scenario: Extension metrics

- **WHEN** exposing TTL extension metrics
- **THEN** the system SHALL provide:
  ```
  # Extension activity
  archerdb_ttl_extensions_total 1000000
  archerdb_ttl_extensions_skipped_total{reason="cooldown"} 500000
  archerdb_ttl_extensions_skipped_total{reason="max_ttl"} 10000
  archerdb_ttl_extensions_skipped_total{reason="max_count"} 5000
  archerdb_ttl_extensions_skipped_total{reason="no_auto_extend"} 2000

  # Extension distribution
  archerdb_entity_extension_count_bucket{le="0"} 500000000
  archerdb_entity_extension_count_bucket{le="1"} 700000000
  archerdb_entity_extension_count_bucket{le="5"} 900000000
  archerdb_entity_extension_count_bucket{le="10"} 950000000
  archerdb_entity_extension_count_bucket{le="+Inf"} 1000000000

  # TTL distribution (current)
  archerdb_entity_ttl_remaining_seconds_bucket{le="3600"} 100000
  archerdb_entity_ttl_remaining_seconds_bucket{le="86400"} 500000
  archerdb_entity_ttl_remaining_seconds_bucket{le="604800"} 800000
  ```

#### Scenario: Extension audit log

- **WHEN** TTL extensions occur
- **THEN** the system MAY log (at debug level):
  - Entity ID
  - Previous expiration
  - New expiration
  - Extension trigger (read operation)
- **AND** audit logging SHALL be optional for performance

### Requirement: Manual TTL Operations

The system SHALL support manual TTL modification for administrative purposes.

#### Scenario: Manual TTL update

- **WHEN** an operator needs to modify entity TTL
- **THEN** the system SHALL support:
  - `archerdb ttl set <entity_id> --ttl=<seconds>`: Set absolute TTL
  - `archerdb ttl extend <entity_id> --by=<seconds>`: Extend by amount
  - `archerdb ttl clear <entity_id>`: Remove TTL (entity never expires)
- **AND** manual operations SHALL bypass cooldown

#### Scenario: Bulk TTL operations

- **WHEN** modifying TTL for many entities
- **THEN** the system SHALL support:
  - `archerdb ttl set-bulk --filter="prefix:vehicle_" --ttl=86400`
  - Rate-limited to avoid impacting production
  - Progress reporting and resumability
- **AND** bulk operations SHALL be logged to audit log

## ADDED Error Codes

### Requirement: TTL Extension Error Codes

The system SHALL define error codes for TTL extension operations.

#### Scenario: New TTL error codes

- **WHEN** TTL extension errors occur
- **THEN** the following error codes SHALL be used:
  | Code | Name | Message | Retry |
  |------|------|---------|-------|
  | 240 | ttl_extension_disabled | TTL extension is not enabled | No |
  | 241 | ttl_extension_max_reached | Entity has reached maximum TTL | No |
  | 242 | ttl_extension_count_exceeded | Entity has reached maximum extension count | No |
  | 243 | ttl_cooldown_active | TTL extension cooldown period active | No |

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| TTL Extension on Read | IMPLEMENTED | All client SDKs |
| TTL Extension Policies | IMPLEMENTED | `src/replication.zig` |
| TTL Extension Observability | IMPLEMENTED | `src/replication.zig` |
| Manual TTL Operations | IMPLEMENTED | All client SDKs |
| TTL Extension Error Codes | IMPLEMENTED | `src/replication.zig` |
