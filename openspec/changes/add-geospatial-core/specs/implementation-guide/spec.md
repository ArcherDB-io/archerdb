# Implementation Guide

## ADDED Requirements

### Requirement: Journal Sizing Validation and Retention Guarantees
The system SHALL validate journal sizing and retention guarantees.

#### Scenario: Journal Sizing Validation
- **WHEN** the system starts up
- **THEN** it SHALL validate that the journal size configuration is sufficient for the configured retention period
- **AND** it SHALL emit a warning if the journal size is less than 2x the retention requirement

### Requirement: Recovery SLA Validation and Benchmarking (F2.3 Gate)
The system SHALL meet recovery SLAs and pass benchmarking gates.

#### Scenario: Recovery SLA Verification
- **WHEN** a node recovers from a crash
- **THEN** the system SHALL measure the recovery time
- **AND** the recovery time SHALL be within the defined SLA (e.g., < 30 seconds for 100GB data)

### Requirement: Query Behavior During Index Recovery
The system SHALL define query behavior during index recovery.

#### Scenario: Query During Recovery
- **WHEN** the index is rebuilding during recovery
- **THEN** queries targeting the recovering range SHALL fail with `index_not_ready` error
- **AND** queries targeting healthy ranges SHALL succeed

### Requirement: F4 VOPR Simulator and Cluster Testing (Weeks 27-32)
The system SHALL undergo VOPR simulation and cluster testing.

#### Scenario: VOPR Simulation
- **WHEN** the F4 phase begins
- **THEN** the VOPR simulator SHALL be run with a variety of fault injection scenarios
- **AND** the system SHALL pass all simulation tests before proceeding to F5

### Requirement: F5 Performance Validation Benchmarks (Weeks 33-38)
The system SHALL pass performance validation benchmarks.

#### Scenario: Performance Benchmarking
- **WHEN** the F5 phase begins
- **THEN** the system SHALL be benchmarked against defined performance targets
- **AND** the results SHALL be documented and compared against baseline metrics

### Requirement: F5 Multi-Batch Retry Semantics (Weeks 37-38)
The system SHALL implement multi-batch retry semantics.

#### Scenario: Multi-Batch Retry
- **WHEN** a multi-batch operation fails partially
- **THEN** the client SDK SHALL retry only the failed batches
- **AND** the retry logic SHALL respect exponential backoff configuration

## Implementation Status

| Requirement | Status | Notes |
| --- | --- | --- |
| Journal Sizing Validation and Retention Guarantees | IMPLEMENTED | `src/archerdb/main.zig` startup warning for <2x retention |
| Recovery SLA Validation and Benchmarking (F2.3 Gate) | PARTIAL | `src/vsr/replica.zig` logs recovery duration + SLA check; classification limited |
| Query Behavior During Index Recovery | PARTIAL | `src/geo_state_machine.zig` gates queries when recovery ranges active |
| F4 VOPR Simulator and Cluster Testing (Weeks 27-32) | NOT IMPLEMENTED | Simulation/cluster runs not wired in repo |
| F5 Performance Validation Benchmarks (Weeks 33-38) | NOT IMPLEMENTED | Benchmarks not wired/documented |
| F5 Multi-Batch Retry Semantics (Weeks 37-38) | NOT IMPLEMENTED | Client SDK retry behavior not implemented |
