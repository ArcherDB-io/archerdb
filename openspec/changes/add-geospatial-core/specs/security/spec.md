# Security Specification

## ADDED Requirements

### Requirement: Mutual TLS (mTLS) Authentication

The system SHALL use mutual TLS for client authentication in production deployments, matching TigerBeetle's security model.

#### Scenario: mTLS requirement

- **WHEN** ArcherDB is configured for production
- **THEN** it SHALL require:
  - Server presents X.509 certificate to clients (server authentication)
  - Clients present X.509 certificate to server (client authentication)
  - Both certificates verified against trusted Certificate Authority (CA)
  - TLS 1.3 minimum (TLS 1.2 deprecated)

#### Scenario: Certificate validation

- **WHEN** validating certificates
- **THEN** the system SHALL verify:
  - Certificate signature against trusted CA
  - Certificate expiration date (not before, not after)
  - Certificate Common Name (CN) or Subject Alternative Name (SAN)
  - Certificate revocation status (CRL/OCSP check - see revocation requirement)

### Requirement: Certificate Revocation Checking

The system SHALL verify certificate revocation status to prevent compromised certificates from being used.

#### Scenario: Revocation checking in production (mandatory)

- **WHEN** running in production mode (`--tls-required=true`)
- **THEN** the system SHALL:
  - Enable revocation checking by default
  - Support both CRL (Certificate Revocation List) and OCSP (Online Certificate Status Protocol)
  - Reject connections with revoked certificates
  - Log revocation check failures as security events
- **AND** revocation checking MAY be disabled via `--tls-revocation-check=disabled`
- **AND** if disabled, log warning: "SECURITY WARNING: Certificate revocation checking disabled"

#### Scenario: CRL configuration

- **WHEN** using CRL-based revocation checking
- **THEN** the system SHALL support:
  ```
  archerdb start \
    --tls-revocation-check=crl \
    --tls-crl-path=/path/to/crl.pem \      # Local CRL file
    --tls-crl-refresh-interval=3600        # Re-fetch interval (seconds)
  ```
- **AND** CRL SHALL be fetched from distribution point in CA certificate if no local path
- **AND** CRL verification failure mode:
  - `--tls-crl-failure-mode=fail-closed` (default): reject connections if CRL unavailable
  - `--tls-crl-failure-mode=fail-open`: allow connections if CRL unavailable (log warning)

#### Scenario: OCSP configuration

- **WHEN** using OCSP-based revocation checking
- **THEN** the system SHALL support:
  ```
  archerdb start \
    --tls-revocation-check=ocsp \
    --tls-ocsp-responder-url=https://ocsp.example.com \  # Override OCSP URL
    --tls-ocsp-timeout=5                                  # Timeout in seconds
  ```
- **AND** OCSP responder URL SHALL be extracted from certificate's AIA extension if not specified
- **AND** OCSP stapling SHALL be supported for reduced latency

#### Scenario: Combined CRL and OCSP

- **WHEN** using both CRL and OCSP
- **THEN** the system SHALL support:
  ```
  archerdb start \
    --tls-revocation-check=both \  # Check CRL first, fall back to OCSP
  ```
- **AND** preference order: local CRL → OCSP → remote CRL fetch
- **AND** this provides defense-in-depth

#### Scenario: Development mode revocation checking

- **WHEN** running in development mode (`--tls-required=false`)
- **THEN** revocation checking SHALL be disabled by default
- **AND** self-signed certificates are accepted
- **AND** no CRL/OCSP infrastructure required for local development

#### Scenario: Revocation check performance

- **WHEN** checking revocation status
- **THEN** the system SHALL:
  - Cache OCSP responses according to their `nextUpdate` field
  - Cache CRL until `nextUpdate` or refresh interval
  - Perform checks asynchronously during TLS handshake where possible
  - Not block VSR consensus messages for revocation checks (pre-validated at connection time)
- **AND** expected overhead:
  - CRL: ~1-5ms initial fetch, ~0ms cached
  - OCSP: ~20-100ms per request (network dependent), ~0ms stapled

#### Scenario: Revocation metrics

- **WHEN** monitoring revocation checking
- **THEN** the following metrics SHALL be exposed:
  ```
  archerdb_tls_revocation_checks_total{result="valid|revoked|unknown"} counter
  archerdb_tls_revocation_check_errors_total{reason="timeout|network|parse"} counter
  archerdb_tls_revoked_connections_rejected_total counter
  archerdb_tls_crl_age_seconds gauge
  archerdb_tls_ocsp_cache_hits_total counter
  ```

#### Scenario: Cipher suite requirements

- **WHEN** negotiating TLS connections
- **THEN** the system SHALL:
  - Use only forward-secret cipher suites (ECDHE)
  - Prefer AES-GCM (hardware-accelerated via AES-NI)
  - Reject weak ciphers (RC4, DES, export ciphers)
  - Use TLS 1.3 preferred cipher suites by default

### Requirement: Development Mode (TLS Optional)

The system SHALL allow disabling TLS for local development and testing.

#### Scenario: Development mode configuration

- **WHEN** starting ArcherDB with `--tls-required=false`
- **THEN** the system SHALL:
  - Accept plaintext TCP connections
  - Skip certificate validation
  - Log warning: "TLS disabled - development mode only"
  - Bind only to localhost by default (prevent accidental exposure)

#### Scenario: Production enforcement

- **WHEN** starting ArcherDB with `--tls-required=true` (default)
- **THEN** the system SHALL:
  - Refuse plaintext connections
  - Require valid certificate paths in configuration
  - Fail to start if certificates are missing or invalid

### Requirement: Certificate Configuration

The system SHALL accept certificate paths via configuration file or command-line flags.

#### Scenario: Server certificate configuration

- **WHEN** configuring server certificates
- **THEN** the following paths SHALL be required:
  - `--tls-cert-path=<path>` - Server certificate (PEM format)
  - `--tls-key-path=<path>` - Server private key (PEM format)
  - `--tls-ca-path=<path>` - CA certificate for verifying clients (PEM format)

#### Scenario: Certificate file format

- **WHEN** loading certificates
- **THEN** files SHALL be:
  - PEM-encoded X.509 certificates
  - Private keys in PKCS#8 or traditional RSA/ECDSA format
  - Optionally encrypted with passphrase (prompted at startup)

#### Scenario: Certificate reload

- **WHEN** certificates are rotated
- **THEN** the system SHALL:
  - Support SIGHUP signal to reload certificates
  - Gracefully transition to new certificates
  - Maintain existing connections until natural close
  - Log certificate reload events

### Requirement: Zero-Downtime Certificate Rotation

The system SHALL support certificate rotation without service interruption.

#### Scenario: Certificate rotation procedure

- **WHEN** rotating certificates
- **THEN** the operator SHALL follow this procedure:
  1. **Preparation Phase**:
     - Generate new certificate with overlapping validity period
     - New cert valid_from <= now, new cert valid_until > old cert valid_until
     - Deploy new cert files alongside old files (don't replace yet)
  2. **Deployment Phase (per replica)**:
     - Copy new certificate to `--tls-cert-path` location
     - Copy new private key to `--tls-key-path` location
     - Send SIGHUP to the ArcherDB process
  3. **Transition Phase**:
     - Server loads new certificate
     - Existing connections continue using old certificate
     - New connections use new certificate
     - Both old and new certificates are temporarily valid
  4. **Completion**:
     - Monitor until all old connections drain (or force close after timeout)
     - Log confirms: "Certificate rotation complete"

#### Scenario: Certificate reload mechanics

- **WHEN** SIGHUP is received
- **THEN** the system SHALL:
  1. Attempt to load new certificate from configured paths
  2. Validate certificate format and chain
  3. If valid: atomically swap certificate in TLS context
  4. If invalid: log error, keep old certificate, increment `archerdb_cert_reload_failures_total`
  5. New connections use new certificate immediately
  6. Existing connections unaffected (TCP connection keeps old TLS session)

#### Scenario: In-flight request handling during rotation

- **WHEN** certificate rotation occurs
- **AND** requests are in-flight
- **THEN** the system SHALL:
  - Complete all in-flight requests normally
  - NOT interrupt VSR protocol messages
  - Existing replica-to-replica connections continue until next reconnect
  - No data loss or consistency issues

#### Scenario: Cluster-wide certificate rotation

- **WHEN** rotating certificates across all replicas
- **THEN** the operator SHALL:
  1. Generate new certificates for all replicas (signed by same CA)
  2. Rotate one replica at a time (rolling update)
  3. Wait for health check to pass before rotating next replica
  4. All replicas should complete rotation within certificate overlap window
- **AND** VSR continues operating throughout (no view changes needed)

#### Scenario: Emergency certificate revocation

- **WHEN** a certificate is compromised
- **THEN** the operator SHALL:
  1. Immediately rotate to new certificate on all replicas
  2. Update CRL (Certificate Revocation List) or OCSP responder
  3. If using CRL/OCSP checking: revoked cert rejected immediately
  4. If not using CRL/OCSP: must wait for rotation to complete
  5. Audit logs for any unauthorized access during compromise window

### Requirement: Replica-to-Replica Authentication

The system SHALL use mTLS for all inter-replica communication (VSR protocol messages).

#### Scenario: Cluster certificate requirements

- **WHEN** replicas communicate
- **THEN** each replica SHALL:
  - Present its own certificate (identifies replica ID)
  - Verify peer certificates against cluster CA
  - Reject connections from unknown replicas
  - Use same TLS configuration as client connections

#### Scenario: Replica identity verification

- **WHEN** a replica connects to another replica
- **THEN** the system SHALL:
  - Extract replica ID from certificate CN (e.g., "replica-0")
  - Verify replica ID matches expected cluster configuration
  - Reject connections from replicas not in configured cluster
  - Prevent "misdirected" messages to wrong cluster

### Requirement: Authorization Model (All-or-Nothing)

The system SHALL grant full read/write access to any authenticated client, matching TigerBeetle's authorization model.

#### Scenario: Access control policy

- **WHEN** a client successfully authenticates via mTLS
- **THEN** the client SHALL have:
  - Full read access (all query operations)
  - Full write access (insert/upsert operations)
  - No per-entity or per-group_id restrictions

#### Scenario: Multi-tenancy approach

- **WHEN** multi-tenancy is required
- **THEN** users SHALL:
  - Run separate ArcherDB clusters per tenant (strong isolation)
  - OR implement application-layer filtering in their service
  - NOT rely on ArcherDB for tenant isolation

#### Scenario: Future authorization extension

- **WHEN** namespace-based authorization is added in future versions
- **THEN** it MAY use:
  - Certificate CN/SAN to encode allowed `group_id` ranges
  - Authorization checks in query engine (filter results)
  - Backward compatibility with all-or-nothing mode

### Requirement: Audit Logging

The system SHALL log authentication and authorization events for security auditing.

#### Scenario: Authentication events

- **WHEN** authentication occurs
- **THEN** the system SHALL log:
  - Client connection established (timestamp, IP, certificate CN)
  - Client authentication success/failure
  - Certificate validation errors (expiration, revocation, untrusted CA)
  - TLS handshake failures

#### Scenario: Operation audit trail

- **WHEN** operations are executed
- **THEN** the system SHALL log:
  - Operation type (insert, query, etc.)
  - Client identity (certificate CN)
  - Timestamp (server monotonic clock)
  - Result (success, error code)
  - Request ID (for tracing)

#### Scenario: Log format

- **WHEN** writing audit logs
- **THEN** they SHALL be:
  - Structured JSON format (machine-parseable)
  - Written to separate audit log file (not mixed with application logs)
  - Rotated daily or by size (prevent unbounded growth)
  - Optionally forwarded to SIEM (via syslog or log shipper)

### Requirement: Secret Management

The system SHALL follow best practices for handling cryptographic secrets.

#### Scenario: Private key security

- **WHEN** handling private keys
- **THEN** the system SHALL:
  - Load keys only at startup (not runtime)
  - Store keys in memory with minimal privileges
  - Zero memory on process exit
  - Never log or expose private key material

#### Scenario: Passphrase handling

- **WHEN** private keys are encrypted
- **THEN** the system SHALL:
  - Prompt for passphrase on stdin at startup
  - Clear passphrase from memory after key decryption
  - Never log or persist passphrase
  - Support environment variable override for automation (with warning)

#### Scenario: File permissions

- **WHEN** verifying certificate files
- **THEN** the system SHALL:
  - Check that private keys have restrictive permissions (0600 or 0400)
  - Warn if private keys are world-readable
  - Optionally refuse to start if permissions are insecure

### Requirement: TLS Performance Optimization

The system SHALL optimize TLS performance to minimize overhead on high-throughput operations.

#### Scenario: Session resumption

- **WHEN** clients reconnect
- **THEN** the system SHALL support:
  - TLS 1.3 session tickets (0-RTT data)
  - Session cache for faster handshakes
  - Ticket rotation for forward secrecy

#### Scenario: Hardware acceleration

- **WHEN** performing cryptographic operations
- **THEN** the system SHALL:
  - Use AES-NI instructions for AES-GCM (server and Aegis checksums)
  - Leverage hardware crypto offload if available
  - Verify AES-NI support at startup (fail if missing)

#### Scenario: Connection pooling

- **WHEN** clients maintain persistent connections
- **THEN** they SHALL:
  - Reuse TLS sessions for multiple requests
  - Avoid repeated handshake overhead
  - Amortize TLS cost across batched operations

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
  - Include in all server certificates (SAN or CN extension)

#### Scenario: Cluster ID in certificates

- **WHEN** issuing certificates for a cluster
- **THEN** the CA SHOULD:
  - Encode cluster ID in certificate (e.g., SAN URI: `archerdb://cluster-<uuid>`)
  - Allow server to verify peer belongs to same cluster
  - Prevent accidental connection to wrong cluster

### Requirement: Security Hardening

The system SHALL follow secure coding practices to minimize attack surface.

#### Scenario: Input validation

- **WHEN** processing untrusted input
- **THEN** the system SHALL:
  - Validate all message sizes before allocation
  - Verify checksums before processing payloads
  - Reject malformed messages immediately
  - Rate-limit connection attempts per IP

#### Scenario: Memory safety

- **WHEN** implementing security-critical code
- **THEN** the system SHALL:
  - Use Zig's safety features (bounds checking, overflow detection)
  - Avoid unsafe pointer arithmetic in parsing code
  - Use compile-time verification where possible
  - Run with `-OReleaseSafe` in production (keep runtime checks)

#### Scenario: Denial of service protection

- **WHEN** under attack
- **THEN** the system SHALL:
  - Limit concurrent connections per client IP (default: 100)
  - Enforce max message size strictly
  - Timeout slow clients (prevent resource exhaustion)
  - Reject excessive batch sizes

### Requirement: Encryption at Rest

The system SHALL support encryption of data at rest through either OS-level or application-level mechanisms.

#### Scenario: Recommended approach (OS-level encryption)

- **WHEN** protecting data at rest
- **THEN** the recommended approach SHALL be:
  - Use OS-level Full Disk Encryption (FDE):
    - Linux: dm-crypt/LUKS, fscrypt
    - macOS: FileVault (APFS)
    - Windows: BitLocker
  - Transparent to ArcherDB (no application changes needed)
  - Leverages hardware AES acceleration (AES-NI)
  - Managed by operating system and infrastructure teams
- **AND** this is the TigerBeetle-recommended approach
- **AND** this separates concerns (database handles consistency, OS handles encryption)

#### Scenario: Encryption at rest compliance requirements

- **WHEN** compliance mandates encryption at rest
- **THEN** the following SHALL be documented:
  ```
  Compliance Standard    | Encryption Requirement
  -----------------------|-------------------------
  PCI-DSS               | Strong cryptography required (AES-128 min)
  HIPAA                 | Encryption recommended (addressable safeguard)
  SOC 2                 | Encryption at rest for sensitive data
  GDPR                  | "Appropriate technical measures" (encryption implied)
  ```
- **AND** FDE with AES-256 satisfies all common compliance requirements
- **AND** operators MUST document encryption configuration for audits

#### Scenario: Encryption verification

- **WHEN** verifying encryption is enabled
- **THEN** operators SHALL:
  - Linux: `dmsetup status` or `lsblk -f` to verify LUKS
  - Check that data file resides on encrypted volume
  - Document encryption algorithm and key length for compliance
- **AND** ArcherDB does NOT verify encryption status (OS responsibility)

#### Scenario: Application-level encryption (optional, future)

- **WHEN** application-level encryption is required (key per entity, compliance needs)
- **THEN** future versions MAY support:
  ```
  archerdb start \
    --encryption-at-rest=enabled \
    --encryption-key-provider=kms \        # AWS KMS, HashiCorp Vault, etc.
    --encryption-algorithm=aes-256-gcm \
    --encryption-key-rotation-days=90
  ```
- **AND** application-level encryption adds:
  - Per-field or per-entity encryption capability
  - Key rotation without re-encrypting data (envelope encryption)
  - Cloud KMS integration for key management
- **BUT** current version (v1) relies on OS-level encryption

#### Scenario: Encryption key management

- **WHEN** managing encryption keys (for OS-level FDE)
- **THEN** operators SHALL:
  - Use cloud KMS for key storage (AWS KMS, GCP KMS, Azure Key Vault)
  - Or use on-premises HSM for air-gapped deployments
  - Implement key rotation procedures
  - Store key recovery materials securely (escrow)
- **AND** key loss = data loss (encryption is not reversible without key)

#### Scenario: Encryption performance impact

- **WHEN** evaluating encryption overhead
- **THEN** expected impact SHALL be:
  ```
  | Encryption Type        | Read Impact | Write Impact | Notes                |
  |------------------------|-------------|--------------|----------------------|
  | FDE (AES-NI hardware)  | <1%         | <1%          | Hardware accelerated |
  | FDE (software)         | 5-15%       | 5-15%        | CPU bound            |
  | App-level (future)     | 3-8%        | 3-8%         | Extra AES operation  |
  ```
- **AND** modern servers with AES-NI have negligible encryption overhead
- **AND** ArcherDB already requires AES-NI for checksums

### Requirement: Compliance and Standards

The system SHALL follow industry security standards for database systems.

#### Scenario: Cryptographic standards

- **WHEN** implementing cryptography
- **THEN** the system SHALL use:
  - NIST-approved algorithms (AES-256, SHA-256, ECDSA P-256)
  - TLS 1.3 (RFC 8446)
  - Aegis-128L for checksums (authenticated encryption)

#### Scenario: Certificate standards

- **WHEN** using X.509 certificates
- **THEN** they SHALL follow:
  - X.509v3 standard
  - Key lengths: RSA ≥2048 bits, ECDSA ≥256 bits
  - SHA-256 or stronger signature algorithms
  - Reasonable validity periods (≤1 year recommended)

#### Scenario: Security documentation

- **WHEN** deploying ArcherDB
- **THEN** documentation SHALL include:
  - TLS setup guide (generating certificates, CA configuration)
  - Security best practices (key rotation, access control)
  - Threat model (what ArcherDB protects against)
  - Incident response procedures (compromise detection, recovery)
