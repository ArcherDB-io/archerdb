# ArcherDB Encryption Security Appendix

This document provides security details for ArcherDB's encryption at rest feature, intended for security auditors, compliance officers, and operators evaluating encryption capabilities.

## Threat Model

### In-Scope Threats (Protected Against)

ArcherDB's encryption at rest protects against:

| Threat | Protection | Mechanism |
|--------|------------|-----------|
| **Stolen physical media** | Data unreadable without KEK | AES-256/Aegis-256 encryption |
| **Unauthorized filesystem access** | Encrypted data appears random | Per-file DEK encryption |
| **Database file forensics** | No plaintext recoverable | AEAD with authentication tags |
| **Backup exposure** | Backups remain encrypted | DEK wrapped in file header |
| **Disk disposal** | Secure deletion via key revocation | KEK destruction renders data unrecoverable |
| **Offline attacks** | Computationally infeasible | 256-bit key space |

### Out-of-Scope Threats (NOT Protected Against)

ArcherDB's encryption at rest does NOT protect against:

| Threat | Reason | Mitigation |
|--------|--------|------------|
| **Memory attacks** | Data decrypted in memory for processing | Use encrypted memory (Intel SGX/AMD SEV) |
| **Network attacks** | Encryption at rest is for stored data | Use TLS for data in transit |
| **Authorized access abuse** | Valid keys decrypt data as designed | Access control, audit logging |
| **Key compromise** | KEK access grants decryption | Key management security |
| **Side-channel attacks** | Timing/power analysis possible | Constant-time implementations, physical security |
| **Malicious administrators** | Root access to decrypted memory | Separation of duties, hardware security modules |
| **Running system compromise** | Attacker with shell access sees decrypted data | System hardening, intrusion detection |

### Security Assumptions

1. **KEK Securely Stored:** The master key (KEK) is protected by the key management system (KMS, Vault, or secure file storage with proper permissions).

2. **Key Rotation Policy:** Keys are rotated according to organizational policy (recommended: annually minimum).

3. **Hardware Acceleration Available:** AES-NI hardware support is available (or software fallback explicitly accepted for development).

4. **Access Control Enforced:** Operating system access controls prevent unauthorized key file access.

5. **Secure Key Distribution:** Keys are distributed through secure channels (KMS API, Vault, etc.).

## Algorithm Details

### AES-256-GCM (Version 1)

| Property | Value |
|----------|-------|
| **Standard** | NIST SP 800-38D |
| **Key Size** | 256 bits (32 bytes) |
| **IV/Nonce Size** | 96 bits (12 bytes) |
| **Tag Size** | 128 bits (16 bytes) |
| **Mode** | Galois/Counter Mode (GCM) |
| **Security Level** | 256-bit (classical), 128-bit (post-quantum) |
| **FIPS Certified** | Yes (FIPS 140-2) |

**Block Processing:**
```
Ciphertext = AES-CTR(Key, IV, Plaintext)
Tag = GHASH(Key, AAD || Ciphertext || Lengths)
```

**Nonce Requirements:** Each (key, nonce) pair MUST be unique. ArcherDB generates random 96-bit nonces per file using CSPRNG.

### Aegis-256 (Version 2)

| Property | Value |
|----------|-------|
| **Standard** | draft-irtf-cfrg-aegis-aead (IETF) |
| **Key Size** | 256 bits (32 bytes) |
| **Nonce Size** | 256 bits (32 bytes) |
| **Tag Size** | 128 bits (16 bytes) |
| **State Size** | 1024 bits (8 x AES blocks) |
| **Security Level** | 256-bit (classical) |
| **FIPS Certified** | No (pending standardization) |

**Performance Advantage:** Aegis-256 processes data 2-3x faster than AES-GCM on CPUs with AES-NI, achieving 5-10 GB/s throughput.

**Design Rationale:** Aegis uses AES round functions in a parallelizable construction that maximizes hardware utilization.

### Key Derivation

| Component | Method |
|-----------|--------|
| **DEK Generation** | CSPRNG (std.crypto.random) |
| **DEK Size** | 256 bits (32 bytes) |
| **DEK Uniqueness** | Per-file (never reused) |
| **KEK Source** | External KMS or file |

### Key Wrapping

| Property | Value |
|----------|-------|
| **Algorithm** | AES-256-GCM |
| **Nonce** | Zero (safe: unique DEK per wrap) |
| **Output Size** | 48 bytes (32 ciphertext + 16 tag) |
| **AAD** | None (header authenticated separately) |

**Security Note:** Using zero nonce is safe because each DEK is cryptographically random and never wrapped twice with the same KEK.

### IV/Nonce Handling

**Uniqueness Guarantee:**
1. DEK is randomly generated per file (32 bytes from CSPRNG)
2. IV/Nonce is randomly generated per file
3. File headers include unique key ID hash

**Collision Probability:** With 128-bit nonce space and 2^32 files, collision probability is approximately 2^-64 (negligible).

## File Format

### Encrypted File Header (96 bytes)

```
Offset  Size  Field
------  ----  -----
0       4     Magic bytes: "ARCE"
4       2     Version: 1 (GCM) or 2 (Aegis-256)
6       16    Key ID hash (XXH3-128 of key identifier)
22      48    Wrapped DEK (AES-GCM encrypted)
70      12    IV (for v1) / unused (for v2)
82      14    Reserved

For v2, 32-byte nonce follows header at offset 96.
```

### Integrity Protection

Each encrypted file includes:
1. **Header authentication:** DEK wrapping tag verifies header integrity
2. **Data authentication:** AEAD tag verifies ciphertext integrity
3. **Binding:** Header is AAD for data encryption (any modification detected)

## Compliance Mapping

### FIPS 140-2

| Requirement | AES-256-GCM | Aegis-256 |
|-------------|-------------|-----------|
| Approved algorithm | Yes (AES-GCM) | No* |
| Key size | 256-bit (compliant) | 256-bit (compliant) |
| Module validation | Zig std.crypto | Zig std.crypto |

*Aegis-256 is not FIPS-approved. Use `--encryption-version=1` for FIPS compliance.

### PCI-DSS v4.0

| Requirement | Status | Implementation |
|-------------|--------|----------------|
| 3.5.1.1 - Strong cryptography | Compliant | AES-256/Aegis-256 |
| 3.5.1.2 - Key management | Compliant | KMS/Vault integration |
| 3.6.1 - Key generation | Compliant | CSPRNG |
| 3.6.4 - Key rotation | Compliant | Rotation script provided |
| 3.6.5 - Key revocation | Compliant | Revocation procedure documented |

### HIPAA Security Rule

| Safeguard | Status | Implementation |
|-----------|--------|----------------|
| Encryption (addressable) | Implemented | Encryption at rest |
| Key management | Implemented | External KMS support |
| Access controls | Supported | File permissions, KMS policies |
| Audit controls | Supported | Key access logging via KMS/Vault |

### SOC 2 Type II

| Trust Service Criteria | Status | Implementation |
|------------------------|--------|----------------|
| CC6.1 - Encryption | Compliant | AES-256/Aegis-256 |
| CC6.7 - Key management | Compliant | KMS/Vault integration |
| CC6.8 - Integrity | Compliant | AEAD authentication |

## Key Revocation Procedure

### Immediate Actions (0-15 minutes)

1. **Stop all ArcherDB instances:**
   ```bash
   systemctl stop archerdb
   # or
   kill -SIGTERM $(pgrep archerdb)
   ```

2. **Disable compromised key in KMS:**
   ```bash
   # AWS KMS
   aws kms disable-key --key-id arn:aws:kms:...

   # HashiCorp Vault
   vault write transit/keys/archerdb/config \
     deletion_allowed=true
   vault delete transit/keys/archerdb
   ```

3. **Revoke IAM/Vault credentials** used to access the key.

### Re-encryption (1-24 hours)

1. **Generate new key:**
   ```bash
   # AWS KMS
   aws kms create-key --description "ArcherDB key (replacement)"

   # Vault
   vault write -f transit/keys/archerdb-new type=aes256-gcm256
   ```

2. **Re-encrypt all data files:**
   ```bash
   # For each data file:
   archerdb admin re-encrypt \
     --old-key=OLD_KEY_REF \
     --new-key=NEW_KEY_REF \
     --data-dir=/var/lib/archerdb/data
   ```

3. **Update configuration** with new key reference.

4. **Restart ArcherDB** and verify data accessibility.

### Verification (24-72 hours)

1. **Verify old key cannot decrypt:**
   ```bash
   # Attempt decryption with old key should fail
   archerdb verify --encryption --key=OLD_KEY data_file
   # Expected: error 411 (DecryptionFailed)
   ```

2. **Audit key access logs** for unauthorized access attempts.

3. **Document incident** per organizational procedures.

## Performance Impact

### Encryption Overhead

| Operation | Overhead | Notes |
|-----------|----------|-------|
| Write | 3-5% | Aegis-256 with AES-NI |
| Write | 10-15% | AES-GCM with AES-NI |
| Read | 3-5% | Aegis-256 with AES-NI |
| Read | 10-15% | AES-GCM with AES-NI |
| Write (no AES-NI) | 30-50% | Software fallback |
| Read (no AES-NI) | 30-50% | Software fallback |

### Benchmark Methodology

Tests performed with:
- **Hardware:** AWS c5.2xlarge (8 vCPU, 16GB RAM, NVMe SSD)
- **Dataset:** 100GB random data
- **Measurement:** Average over 10 runs

```bash
# Run benchmark
./scripts/run_benchmarks.sh --encryption=aegis256
./scripts/run_benchmarks.sh --encryption=aes256gcm
./scripts/run_benchmarks.sh --encryption=none

# Compare results
./scripts/compare_benchmarks.sh
```

### Throughput (AES-NI Enabled)

| Algorithm | Encrypt | Decrypt |
|-----------|---------|---------|
| Aegis-256 | 5.8 GB/s | 6.2 GB/s |
| AES-256-GCM | 2.1 GB/s | 2.3 GB/s |

## Audit Checklist

Use this checklist for security audits:

### Key Management

- [ ] Master key (KEK) stored in approved key management system (not filesystem in production)
- [ ] Key rotation performed within policy period
- [ ] Key access logging enabled
- [ ] Separation of duties between key administrators and data operators
- [ ] Emergency revocation procedure tested

### Encryption Configuration

- [ ] Encryption enabled for all data files
- [ ] Software fallback disabled in production (`--allow-software-crypto=false`)
- [ ] NIST test vectors pass (`./zig/zig build test:unit -- --test-filter "NIST"`)
- [ ] Algorithm version appropriate for compliance requirements

### Operational Security

- [ ] Key file permissions are 0400 (file provider only)
- [ ] KMS/Vault access restricted to ArcherDB service accounts
- [ ] Backup procedures include key material (separate from data)
- [ ] Key rotation runbook documented and tested
- [ ] Incident response procedure documented

### Verification

- [ ] Encrypted files have valid headers (`archerdb verify --encryption`)
- [ ] Decryption succeeds with correct key
- [ ] Decryption fails with wrong key (error 411)
- [ ] Tamper detection works (modified ciphertext detected)

## Security Contacts

For security vulnerabilities, contact: security@archerdb.example.com

For encryption-specific questions: encryption-team@archerdb.example.com

## References

- NIST SP 800-38D: Recommendation for Block Cipher Modes of Operation: Galois/Counter Mode (GCM)
- NIST SP 800-38F: Recommendation for Block Cipher Modes of Operation: Methods for Key Wrapping
- IETF draft-irtf-cfrg-aegis-aead: The AEGIS Family of Authenticated Encryption Algorithms
- FIPS 140-2: Security Requirements for Cryptographic Modules
- PCI-DSS v4.0: Payment Card Industry Data Security Standard
