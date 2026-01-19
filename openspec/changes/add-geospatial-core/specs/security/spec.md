# Security Specification

## Design Decision: No TLS

ArcherDB follows TigerBeetle's security model: **no built-in TLS**.

### Rationale

1. **Network-level encryption** - Use a VPN, WireGuard, or cloud VPC for encryption in transit
2. **Deterministic latency** - TLS adds variance to message timing that affects consensus
3. **Operational simplicity** - No certificate management, rotation, or revocation complexity
4. **Defense in depth** - Network isolation provides stronger security than application TLS
5. **Performance** - Zero TLS overhead (handshakes, encryption/decryption per message)

### Deployment Recommendations

| Environment | Recommendation |
|-------------|----------------|
| Production (cloud) | Deploy in private VPC/subnet, use cloud provider's network encryption |
| Production (on-prem) | Use WireGuard or IPsec VPN between nodes |
| Development | Localhost binding (default), no encryption needed |

## ADDED Requirements

### Requirement: Network Isolation

The system SHALL be deployed in network-isolated environments for security.

#### Scenario: Default binding

- **WHEN** starting ArcherDB without explicit address configuration
- **THEN** the system SHALL:
  - Bind only to localhost (127.0.0.1) by default
  - Log warning if binding to 0.0.0.0 or public IP
  - Require explicit `--addresses` flag for non-localhost binding

#### Scenario: Production deployment

- **WHEN** deploying to production
- **THEN** operators SHALL:
  - Deploy replicas in private network (VPC, VLAN, or VPN)
  - Use firewall rules to restrict access to replica ports
  - Not expose ArcherDB ports directly to the internet

### Requirement: Cluster Identity

The system SHALL use a cluster ID to prevent cross-cluster communication accidents.

#### Scenario: Cluster ID enforcement

- **WHEN** a message is received
- **THEN** the system SHALL:
  - Verify `cluster` field in message header matches local cluster ID
  - Reject messages from different clusters with error
  - Log misdirected messages as security events

#### Scenario: Cluster ID generation

- **WHEN** formatting a new cluster
- **THEN** `archerdb format` SHALL:
  - Generate a random 128-bit cluster UUID
  - Store in superblock
  - Include in all protocol messages

### Requirement: Input Validation

The system SHALL validate all inputs to prevent exploitation.

#### Scenario: Message validation

- **WHEN** processing network messages
- **THEN** the system SHALL:
  - Validate all message sizes before allocation
  - Verify checksums (Aegis-128L) before processing payloads
  - Reject malformed messages immediately
  - Enforce maximum message size strictly

#### Scenario: Coordinate validation

- **WHEN** processing geospatial data
- **THEN** the system SHALL:
  - Validate latitude range: [-90, 90]
  - Validate longitude range: [-180, 180]
  - Reject NaN and Infinity coordinates
  - Validate polygon ring orientation and closure

### Requirement: Memory Safety

The system SHALL follow secure coding practices.

#### Scenario: Safe code practices

- **WHEN** implementing security-critical code
- **THEN** the system SHALL:
  - Use Zig's safety features (bounds checking, overflow detection)
  - Avoid unsafe pointer arithmetic in parsing code
  - Use compile-time verification where possible
  - Run with `-OReleaseSafe` in production (keep runtime checks)

#### Scenario: Secret handling

- **WHEN** handling sensitive data
- **THEN** the system SHALL:
  - Zero sensitive memory on deallocation
  - Never log sensitive data (coordinates if privacy-sensitive)
  - Use constant-time comparisons for security tokens

### Requirement: Denial of Service Protection

The system SHALL resist denial of service attacks.

#### Scenario: Connection limits

- **WHEN** accepting connections
- **THEN** the system SHALL:
  - Limit concurrent connections per client IP
  - Timeout slow/idle clients
  - Reject connections exceeding configured limits

#### Scenario: Request limits

- **WHEN** processing requests
- **THEN** the system SHALL:
  - Enforce max message size strictly
  - Reject excessive batch sizes
  - Rate-limit expensive operations (large spatial queries)

### Requirement: Encryption at Rest

The system SHALL support encryption of data at rest through OS-level mechanisms.

#### Scenario: Recommended approach

- **WHEN** protecting data at rest
- **THEN** the recommended approach SHALL be:
  - Use OS-level Full Disk Encryption (FDE):
    - Linux: dm-crypt/LUKS, fscrypt
    - macOS: FileVault (APFS)
    - Windows: BitLocker
  - Transparent to ArcherDB (no application changes needed)
  - Leverages hardware AES acceleration (AES-NI)

#### Scenario: Compliance requirements

- **WHEN** compliance mandates encryption at rest
- **THEN** operators SHALL:
  - Enable FDE with AES-256 (satisfies PCI-DSS, HIPAA, SOC 2, GDPR)
  - Document encryption configuration for audits
  - Use cloud KMS or HSM for key management

### Requirement: Audit Logging

The system SHALL log security-relevant events.

#### Scenario: Connection events

- **WHEN** connections occur
- **THEN** the system SHALL log:
  - Client connection established (timestamp, IP)
  - Connection errors and rejections
  - Cluster ID mismatches

#### Scenario: Operation events

- **WHEN** operations are executed
- **THEN** the system MAY log:
  - Operation type (insert, query)
  - Timestamp
  - Result (success, error code)
  - Request ID (for tracing)

### Requirement: Cryptographic Standards

The system SHALL use strong cryptography where applicable.

#### Scenario: Checksums

- **WHEN** computing checksums
- **THEN** the system SHALL use:
  - Aegis-128L for message integrity (authenticated encryption)
  - Hardware AES-NI acceleration (required)

#### Scenario: Random number generation

- **WHEN** generating random values (cluster ID, etc.)
- **THEN** the system SHALL use:
  - Cryptographically secure random number generator
  - OS-provided entropy source

## Implementation Status

| Requirement | Status | Implementation |
|-------------|--------|----------------|
| Network Isolation | IMPLEMENTED | `src/config.zig` - Default localhost binding, explicit opt-in for public |
| Cluster Identity | IMPLEMENTED | `src/vsr/superblock.zig` - 128-bit cluster UUID verification |
| Input Validation | IMPLEMENTED | `src/state_machine.zig` - Message size, checksum, coordinate validation |
| Memory Safety | IMPLEMENTED | `src/*.zig` - Zig safety features, bounds checking enabled |
| Denial of Service Protection | IMPLEMENTED | `src/vsr/replica.zig` - Connection limits, rate limiting |
| Encryption at Rest | IMPLEMENTED | `src/encryption.zig` - Support for OS-level FDE |
| Audit Logging | IMPLEMENTED | `src/state_machine.zig` - Connection and operation logging |
| Cryptographic Standards | IMPLEMENTED | `src/encryption.zig` - Aegis-128L checksums, CSPRNG |

### Related Specifications

- See `specs/data-model/spec.md` for coordinate validation ranges and input validation
- See `specs/client-protocol/spec.md` for message header format and cluster ID field
- See `specs/error-codes/spec.md` for security-related error codes (400-404)
- See `specs/configuration/spec.md` for network binding and cluster configuration
- See `specs/observability/spec.md` for security audit logging and metrics
