# Configuration - Hardware-Accelerated AES-NI Encryption

## ADDED Requirements

### Requirement: Software Crypto Bypass Flag

The system SHALL support bypassing AES-NI requirement for testing environments.

#### Scenario: CLI flag for software crypto bypass

- **WHEN** starting ArcherDB without AES-NI hardware
- **THEN** the operator MAY specify:
  ```
  --allow-software-crypto=true
  ```
- **AND** this flag SHALL enable software AES fallback
- **AND** this flag SHALL NOT be used in production

#### Scenario: Default behavior (no bypass)

- **WHEN** `--allow-software-crypto` is not specified
- **THEN** the default SHALL be `false`
- **AND** startup SHALL fail if AES-NI is not available
- **AND** this ensures production deployments use hardware acceleration

#### Scenario: Warning when bypass enabled

- **WHEN** `--allow-software-crypto=true` is specified
- **THEN** the system SHALL log at WARN level:
  ```
  warn: Software crypto fallback enabled (NOT RECOMMENDED FOR PRODUCTION)
  warn: Encryption performance will be ~10x slower than hardware-accelerated
  warn: Expected throughput: ~150 MB/s (vs >3 GB/s with AES-NI)
  ```
- **AND** this warning SHALL be logged even if AES-NI is available

#### Scenario: Bypass flag in help text

- **WHEN** displaying `archerdb --help`
- **THEN** the flag SHALL be documented:
  ```
  Encryption options:
    --allow-software-crypto=<bool>
        Allow software AES fallback when AES-NI hardware is not available.
        NOT RECOMMENDED FOR PRODUCTION - 10x slower than hardware.
        Use only for testing in VMs without AES-NI support.
        Default: false
  ```

#### Scenario: Configuration validation

- **WHEN** `--allow-software-crypto=true` is specified
- **AND** `--encryption-enabled=false` is also specified
- **THEN** the system SHALL log at INFO level:
  ```
  info: --allow-software-crypto ignored (encryption not enabled)
  ```
- **AND** the flag SHALL have no effect when encryption is disabled

### Requirement: Hardware Requirement Documentation

The system SHALL document AES-NI hardware requirements.

#### Scenario: Display hardware requirements at startup

- **WHEN** encryption is enabled
- **THEN** the system SHALL log at startup:
  ```
  info: Encryption at rest: enabled
  info: Cipher: Aegis-256 (AES-NI accelerated)
  info: Key provider: aws-kms
  info: Hardware: AES-NI available ✓
  ```

#### Scenario: Hardware check error message

- **WHEN** AES-NI is not available
- **AND** `--allow-software-crypto` is not set
- **THEN** the error message SHALL include:
  ```
  error: AES-NI hardware acceleration required for encryption

  Your CPU does not support AES-NI instructions. Options:

  1. Use hardware with AES-NI support
     All Intel CPUs since Westmere (2010) and AMD CPUs since Bulldozer (2011)
     support AES-NI. Most modern x86-64 servers have AES-NI.

  2. Disable encryption
     --encryption-enabled=false

  3. Use software fallback (TESTING ONLY)
     --allow-software-crypto=true
     WARNING: 10x slower, do NOT use in production

  To check AES-NI support on Linux:
     grep aes /proc/cpuinfo
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Software Crypto Bypass Flag | IMPLEMENTED | `src/encryption.zig` |
| Hardware Requirement Documentation | IMPLEMENTED | `src/encryption.zig` |

## Related Specifications

- See `security/spec.md` (this change) for AES-NI requirement details
- See `observability/spec.md` (this change) for hardware status metrics
- See base `configuration/spec.md` for CLI argument parsing
