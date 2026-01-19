# Security v2 Spec Deltas

## ADDED Requirements

### Requirement: Encryption at Rest

The system SHALL support encryption of all persistent data using AES-256-GCM with hardware acceleration.

#### Scenario: Data file encryption

- **WHEN** encryption at rest is enabled
- **THEN** the system SHALL encrypt:
  - Data files (LSM tables, WAL journal)
  - Index structures persisted to disk
  - Checkpoint files
  - Backup files
- **AND** encryption SHALL use AES-256-GCM with AES-NI acceleration
- **AND** each file SHALL have a unique Data Encryption Key (DEK)

#### Scenario: Encryption configuration

- **WHEN** configuring encryption at rest
- **THEN** the operator SHALL provide:
  ```
  --encryption-enabled=true
  --encryption-key-provider=<aws-kms|vault|file>
  --encryption-key-id=<key-identifier>
  ```
- **AND** encryption SHALL be enabled at cluster creation
- **AND** enabling encryption on existing data SHALL require migration

#### Scenario: Encrypted file format

- **WHEN** writing an encrypted file
- **THEN** the file format SHALL be:
  ```
  ┌────────────────────────────────────────┐
  │ Magic: "ARCE" (4 bytes)                │  Encrypted file marker
  │ Version: u16 (2 bytes)                 │  Format version
  │ Key ID Hash: u128 (16 bytes)           │  For key lookup
  │ Wrapped DEK: [48]u8                    │  AES-256 key wrapped with KEK
  │ IV: [12]u8                             │  GCM initialization vector
  │ Reserved: [14]u8                       │  Future use
  └────────────────────────────────────────┘
  │ Encrypted Data Blocks                  │  AES-256-GCM encrypted
  │ ...                                    │
  └────────────────────────────────────────┘
  │ Auth Tag: [16]u8                       │  GCM authentication tag
  └────────────────────────────────────────┘
  ```
- **AND** header SHALL be 96 bytes for alignment

#### Scenario: Encryption performance

- **WHEN** encryption is enabled with AES-NI
- **THEN** performance overhead SHALL be:
  - Write throughput: <5% reduction
  - Read latency: <1% increase
  - CPU utilization: <3% increase
- **AND** AES-NI SHALL be required (fail startup without it)

### Requirement: Key Management Integration

The system SHALL integrate with external key management systems for master key storage.

#### Scenario: AWS KMS integration

- **WHEN** using AWS KMS as key provider
- **THEN** the system SHALL:
  - Authenticate using IAM role or access keys
  - Retrieve master key (KEK) from KMS
  - Use KMS for DEK wrapping/unwrapping
  - Cache unwrapped KEK in memory (configurable TTL)
- **AND** KMS calls SHALL be audited

#### Scenario: HashiCorp Vault integration

- **WHEN** using Vault as key provider
- **THEN** the system SHALL:
  - Authenticate using AppRole or Kubernetes auth
  - Retrieve master key from Vault transit engine
  - Use Vault for DEK wrapping/unwrapping
  - Support Vault namespaces for multi-tenant
- **AND** Vault token renewal SHALL be automatic

#### Scenario: File-based key (development only)

- **WHEN** using file-based key provider
- **THEN** the system SHALL:
  - Read 32-byte master key from specified file
  - Log warning about production unsuitability
  - Support key file for CI/testing environments
- **AND** file permissions SHALL be validated (0400 or stricter)

#### Scenario: Key unavailability

- **WHEN** the key provider is unavailable at startup
- **THEN** the system SHALL:
  - Retry with exponential backoff (1s, 2s, 4s... max 60s)
  - Fail startup after max retries (configurable)
  - Log clear error message with troubleshooting steps
- **AND** running nodes SHALL continue operating with cached KEK

### Requirement: Key Rotation

The system SHALL support rotation of encryption keys without downtime.

#### Scenario: Master key rotation

- **WHEN** operator initiates master key rotation
- **THEN** the system SHALL:
  1. Generate or retrieve new master key (KEK v2)
  2. Re-wrap all DEKs with new KEK
  3. Update file headers with new wrapped DEKs
  4. Mark old KEK for deletion (grace period)
- **AND** rotation SHALL NOT require data re-encryption

#### Scenario: Data encryption key rotation

- **WHEN** DEK rotation is required (security policy)
- **THEN** the system SHALL:
  1. Generate new DEK for affected files
  2. Re-encrypt data blocks with new DEK
  3. Update file header with new wrapped DEK
  4. Securely delete old DEK
- **AND** DEK rotation SHALL be background operation

#### Scenario: Rotation progress tracking

- **WHEN** key rotation is in progress
- **THEN** the system SHALL expose:
  ```
  archerdb_encryption_rotation_status{key_type="kek"} 1  # 0=idle, 1=rotating
  archerdb_encryption_rotation_progress{key_type="kek"} 0.75
  archerdb_encryption_keys_rotated_total 5
  ```
- **AND** rotation completion SHALL be logged to audit log

### Requirement: Encryption Verification

The system SHALL provide tools to verify encryption integrity.

#### Scenario: Verify encryption command

- **WHEN** operator runs `archerdb verify --encryption`
- **THEN** the system SHALL:
  - Verify all data files have encryption headers
  - Verify DEKs can be unwrapped with current KEK
  - Verify GCM auth tags for data integrity
  - Report any unencrypted or corrupted files
- **AND** verification SHALL be non-destructive

#### Scenario: Encryption status endpoint

- **WHEN** checking encryption status via API
- **THEN** the system SHALL return:
  ```json
  {
    "encryption_enabled": true,
    "key_provider": "aws-kms",
    "kek_id": "arn:aws:kms:...",
    "kek_rotation_date": "2025-01-01T00:00:00Z",
    "encrypted_files": 1234,
    "unencrypted_files": 0
  }
  ```

### Requirement: Encryption Audit Logging

The system SHALL log all encryption-related operations for compliance.

#### Scenario: Key access logging

- **WHEN** a key operation occurs
- **THEN** the system SHALL log:
  - Key retrieval from provider
  - DEK unwrap operations
  - Key rotation events
  - Failed decryption attempts
- **AND** logs SHALL include timestamp, operation, key ID, and result

#### Scenario: Encryption metrics

- **WHEN** exposing encryption metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_encryption_operations_total{op="encrypt"} 1000000
  archerdb_encryption_operations_total{op="decrypt"} 5000000
  archerdb_encryption_key_cache_hits_total 4999000
  archerdb_encryption_key_cache_misses_total 1000
  archerdb_encryption_failures_total{reason="auth_tag_mismatch"} 0
  ```

## ADDED Error Codes

### Requirement: Encryption Error Codes

The system SHALL define error codes for encryption operations.

#### Scenario: New encryption error codes

- **WHEN** encryption errors occur
- **THEN** the following error codes SHALL be used:
  | Code | Name | Message | Retry |
  |------|------|---------|-------|
  | 410 | encryption_key_unavailable | Cannot retrieve encryption key from provider | Yes |
  | 411 | decryption_failed | Failed to decrypt data (auth tag mismatch) | No |
  | 412 | encryption_not_enabled | Encryption required but not configured | No |
  | 413 | key_rotation_in_progress | Key rotation in progress, retry later | Yes |
  | 414 | unsupported_encryption_version | File encrypted with unsupported version | No |

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Encryption at Rest | IMPLEMENTED | `src/encryption.zig` |
| Key Management Integration | IMPLEMENTED | `src/encryption.zig` |
| Key Rotation | IMPLEMENTED | `src/encryption.zig` |
| Encryption Verification | IMPLEMENTED | `src/encryption.zig` |
| Encryption Audit Logging | IMPLEMENTED | `src/encryption.zig` |
| Encryption Error Codes | IMPLEMENTED | `src/encryption.zig` |
