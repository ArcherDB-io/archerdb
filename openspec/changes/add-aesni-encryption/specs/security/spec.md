# Security - Hardware-Accelerated AES-NI Encryption

## MODIFIED Requirements

### Requirement: Encryption at Rest (Modified)

Upgrades encryption cipher from AES-256-GCM to Aegis-256 with explicit AES-NI requirement.

#### Scenario: Aegis-256 cipher for data encryption

- **WHEN** encryption at rest is enabled
- **THEN** the system SHALL use Aegis-256 cipher:
  - 256-bit key (DEK)
  - 256-bit nonce (random per file)
  - 256-bit authentication tag
- **AND** Aegis-256 SHALL provide authenticated encryption (AEAD)
- **AND** Aegis-256 SHALL require AES-NI hardware acceleration

#### Scenario: Hardware acceleration requirement

- **WHEN** starting ArcherDB with encryption enabled
- **THEN** the system SHALL verify AES-NI hardware support:
  - Check CPU feature flags for AES-NI (`x86.aes` feature)
  - Log hardware status at INFO level
- **AND** if AES-NI is NOT available:
  - If `--allow-software-crypto=true`: warn and continue with software fallback
  - Otherwise: fail startup with error `AesNiNotAvailable` (code 415)

#### Scenario: Software crypto bypass for testing

- **WHEN** `--allow-software-crypto=true` is specified
- **AND** AES-NI is not available
- **THEN** the system SHALL:
  - Log WARNING: "AES-NI not available, using software fallback (10x slower)"
  - Continue with software AES implementation
  - Set metric `archerdb_encryption_using_software` to 1
- **AND** this mode SHALL NOT be used in production

#### Scenario: Encryption performance with AES-NI

- **WHEN** encryption is enabled with AES-NI
- **THEN** performance SHALL meet:
  - Encryption throughput: >3 GB/s (Aegis-256)
  - Write overhead: <3% reduction
  - Read overhead: <1% increase
  - CPU utilization: <2% increase
- **AND** performance SHALL be significantly better than software fallback (~10x)

### Requirement: Encryption File Format (Modified)

Updates file format to support Aegis-256 cipher with backward compatibility.

#### Scenario: Encryption format version

- **WHEN** writing encrypted files
- **THEN** the format version field SHALL indicate cipher:
  - `version=1`: AES-256-GCM (legacy, read-only support)
  - `version=2`: Aegis-256 (current, write default)
- **AND** header size SHALL remain 96 bytes

#### Scenario: Encrypted file header format (v2)

- **WHEN** writing an encrypted file with Aegis-256
- **THEN** the file format SHALL be:
  ```
  ┌────────────────────────────────────────┐
  │ Magic: "ARCE" (4 bytes)                │  Encrypted file marker
  │ Version: u16 = 2 (2 bytes)             │  Aegis-256 cipher
  │ Key ID Hash: u128 (16 bytes)           │  For key lookup
  │ Wrapped DEK: [48]u8                    │  256-bit key wrapped with KEK
  │ Nonce: [32]u8                          │  256-bit nonce (was 12 for GCM)
  └────────────────────────────────────────┘  = 102 bytes, padded to 128
  │ Encrypted Data Blocks                  │  Aegis-256 encrypted
  │ ...                                    │
  └────────────────────────────────────────┘
  │ Auth Tag: [32]u8                       │  256-bit Aegis tag
  └────────────────────────────────────────┘
  ```
- **AND** nonce SHALL be 32 bytes (Aegis-256 requirement)
- **AND** auth tag SHALL be 32 bytes (256-bit security)

#### Scenario: Backward compatibility with v1 files

- **WHEN** reading an encrypted file
- **AND** version field is 1 (AES-256-GCM)
- **THEN** the system SHALL:
  - Use AES-256-GCM for decryption
  - Use 12-byte nonce and 16-byte tag
  - Successfully decrypt legacy files
- **AND** v1 files SHALL NOT be rewritten (read-only support)

#### Scenario: Automatic cipher upgrade on compaction

- **WHEN** compaction rewrites data blocks
- **AND** source file is v1 (AES-256-GCM)
- **THEN** output file SHALL be v2 (Aegis-256)
- **AND** this provides automatic migration to better cipher

## ADDED Requirements

### Requirement: AES-NI Detection and Validation

The system SHALL explicitly detect and validate AES-NI hardware support.

#### Scenario: AES-NI detection at startup

- **WHEN** ArcherDB starts
- **THEN** the system SHALL:
  - Check CPU feature flags for AES-NI support
  - Log detection result at INFO level:
    ```
    info: AES-NI hardware acceleration: available
    ```
    or
    ```
    warn: AES-NI hardware acceleration: NOT available
    ```

#### Scenario: Startup failure without AES-NI

- **WHEN** AES-NI is not available
- **AND** `--allow-software-crypto` is not set
- **THEN** the system SHALL:
  - Log error with guidance:
    ```
    error: AES-NI required for encryption but not available
    error: This hardware does not support AES-NI instructions
    error: Options:
    error:   1. Use hardware with AES-NI support (all modern x86-64 CPUs)
    error:   2. Disable encryption (--encryption-enabled=false)
    error:   3. Use software fallback (--allow-software-crypto=true, NOT FOR PRODUCTION)
    ```
  - Exit with error code 415 (AesNiNotAvailable)

#### Scenario: Supported CPU architectures

- **WHEN** checking for AES-NI support
- **THEN** the following architectures SHALL be checked:
  - `x86_64`: Check for `aes` CPU feature
  - `x86` (32-bit): Check for `aes` CPU feature
  - Other architectures: Return false (AES-NI is x86-specific)
- **AND** future ARM64 NEON support is out of scope for this change

## ADDED Error Codes

### Requirement: AES-NI Error Code

#### Scenario: New error code for missing AES-NI

- **WHEN** AES-NI is required but not available
- **THEN** error code 415 SHALL be returned:
  | Code | Name | Message | Retry |
  |------|------|---------|-------|
  | 415 | aesni_not_available | AES-NI hardware acceleration required but not available | No |

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Encryption at Rest (Modified) | IMPLEMENTED | `src/encryption.zig` |
| Encryption File Format (Modified) | IMPLEMENTED | `src/encryption.zig` |
| AES-NI Detection and Validation | IMPLEMENTED | `src/encryption.zig` |
| AES-NI Error Code | IMPLEMENTED | `src/encryption.zig` |

## Related Specifications

- See `observability/spec.md` (this change) for encryption hardware metrics
- See `configuration/spec.md` (this change) for software crypto bypass flag
- See base `security/spec.md` for encryption at rest requirements
