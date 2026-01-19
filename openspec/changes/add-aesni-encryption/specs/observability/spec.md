# Observability - Hardware-Accelerated AES-NI Encryption

## ADDED Requirements

### Requirement: AES-NI Hardware Status Metric

The system SHALL expose metrics indicating AES-NI hardware availability.

#### Scenario: AES-NI availability metric

- **WHEN** exposing encryption hardware metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_encryption_aesni_available Whether AES-NI hardware acceleration is available (1=yes, 0=no)
  # TYPE archerdb_encryption_aesni_available gauge
  archerdb_encryption_aesni_available 1
  ```
- **AND** this metric SHALL be set at startup
- **AND** value SHALL NOT change during process lifetime

#### Scenario: Software fallback metric

- **WHEN** software crypto fallback is active
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_encryption_using_software Whether using software crypto fallback (1=yes, 0=no)
  # TYPE archerdb_encryption_using_software gauge
  archerdb_encryption_using_software 0
  ```
- **AND** value 1 indicates `--allow-software-crypto=true` was used without AES-NI
- **AND** operators SHOULD alert if this metric is 1 in production

### Requirement: Encryption Cipher Metric

The system SHALL expose the encryption cipher in use.

#### Scenario: Cipher version metric

- **WHEN** exposing encryption metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_encryption_cipher_version Encryption cipher version in use (1=AES-GCM, 2=Aegis-256)
  # TYPE archerdb_encryption_cipher_version gauge
  archerdb_encryption_cipher_version 2
  ```
- **AND** value 2 indicates Aegis-256 (current)
- **AND** value 1 indicates AES-256-GCM (legacy)

### Requirement: Encryption Throughput Metric

The system SHALL expose encryption throughput for performance monitoring.

#### Scenario: Encryption throughput metric

- **WHEN** exposing encryption performance metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_encryption_throughput_bytes Rolling average encryption throughput in bytes/second
  # TYPE archerdb_encryption_throughput_bytes gauge
  archerdb_encryption_throughput_bytes{operation="encrypt"} 4294967296
  archerdb_encryption_throughput_bytes{operation="decrypt"} 4831838208
  ```
- **AND** throughput SHALL be calculated as rolling 10-second average
- **AND** this enables performance regression detection

#### Scenario: Alerting on software fallback

- **WHEN** configuring production alerts
- **THEN** operators SHOULD configure:
  ```yaml
  Alert: Encryption using software fallback
  Condition: archerdb_encryption_using_software == 1
  Severity: Critical
  Message: Node using software crypto (10x slower than hardware)
  ```
- **AND** this alert catches misconfigured production nodes

#### Scenario: Alerting on low throughput

- **WHEN** configuring performance alerts
- **THEN** operators MAY configure:
  ```yaml
  Alert: Encryption throughput degraded
  Condition: archerdb_encryption_throughput_bytes{operation="encrypt"} < 1000000000
  Severity: Warning
  Message: Encryption throughput below 1GB/s, check AES-NI status
  ```
- **AND** expected throughput with AES-NI is >3 GB/s

## MODIFIED Requirements

### Requirement: Encryption Metrics (Modified)

Extends existing encryption metrics with hardware and performance tracking.

#### Scenario: Combined encryption metrics

- **WHEN** exposing all encryption metrics
- **THEN** the system SHALL provide:
  ```
  # Hardware status
  archerdb_encryption_aesni_available 1
  archerdb_encryption_using_software 0
  archerdb_encryption_cipher_version 2

  # Operations (existing)
  archerdb_encryption_operations_total{op="encrypt"} 1000000
  archerdb_encryption_operations_total{op="decrypt"} 5000000

  # Cache (existing)
  archerdb_encryption_key_cache_hits_total 4999000
  archerdb_encryption_key_cache_misses_total 1000

  # Bytes (existing)
  archerdb_encryption_bytes_total{op="encrypt"} 128000000000
  archerdb_encryption_bytes_total{op="decrypt"} 640000000000

  # Performance (new)
  archerdb_encryption_throughput_bytes{operation="encrypt"} 4294967296
  archerdb_encryption_throughput_bytes{operation="decrypt"} 4831838208
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| AES-NI Hardware Status Metric | IMPLEMENTED | `src/encryption.zig` |
| Encryption Cipher Metric | IMPLEMENTED | `src/encryption.zig` |
| Encryption Throughput Metric | IMPLEMENTED | `src/encryption.zig` |
| Encryption Metrics (Modified) | IMPLEMENTED | `src/encryption.zig` |

## Related Specifications

- See `security/spec.md` (this change) for AES-NI requirement details
- See `configuration/spec.md` (this change) for `--allow-software-crypto` flag
- See base `observability/spec.md` for Prometheus endpoint configuration
