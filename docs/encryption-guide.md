# ArcherDB Encryption Guide

This guide covers encryption at rest configuration, key management, and operational procedures for ArcherDB.

## Overview

ArcherDB supports encryption at rest using industry-standard authenticated encryption algorithms:

- **Aegis-256** (default, v2): High-performance AEAD cipher optimized for AES-NI
- **AES-256-GCM** (v1): NIST-certified, widely compatible

All data files are encrypted with per-file Data Encryption Keys (DEKs), which are wrapped with a Master Key (KEK) stored in your key management system.

```
                    +-------------------+
                    |  Key Management   |
                    |  (KMS/Vault/File) |
                    +--------+----------+
                             |
                             | KEK (Master Key)
                             v
+----------------+     +------------+     +-----------------+
| Data File      | <-- | Wrapped    | <-- | Data Encryption |
| (Encrypted)    |     | DEK Header |     | Key (DEK)       |
+----------------+     +------------+     +-----------------+
```

## Getting Started

### Prerequisites

- ArcherDB compiled with encryption support
- Key management system configured (KMS, Vault, or file-based for development)
- AES-NI hardware support (recommended) or `--allow-software-crypto` flag

### Quick Start (Development)

1. **Generate a key file:**
   ```bash
   openssl rand -out /etc/archerdb/key.bin 32
   chmod 400 /etc/archerdb/key.bin
   ```

2. **Start ArcherDB with encryption:**
   ```bash
   archerdb start \
     --encryption-enabled=true \
     --encryption-key-provider=file \
     --encryption-key-path=/etc/archerdb/key.bin
   ```

3. **Verify encryption is active:**
   ```bash
   archerdb verify --encryption /var/lib/archerdb/data/0_0.archerdb
   # Output: "Encryption: ENABLED (v2 Aegis-256)"
   ```

### Production Setup (AWS KMS)

1. **Create a KMS key:**
   ```bash
   aws kms create-key \
     --description "ArcherDB encryption key" \
     --key-usage ENCRYPT_DECRYPT \
     --key-spec SYMMETRIC_DEFAULT
   ```

2. **Configure ArcherDB:**
   ```bash
   archerdb start \
     --encryption-enabled=true \
     --encryption-key-provider=aws-kms \
     --encryption-key-id=arn:aws:kms:us-east-1:123456789012:key/abc123
   ```

3. **Grant IAM permissions:**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": [
         "kms:Encrypt",
         "kms:Decrypt",
         "kms:GenerateDataKey"
       ],
       "Resource": "arn:aws:kms:us-east-1:123456789012:key/abc123"
     }]
   }
   ```

### Production Setup (HashiCorp Vault)

1. **Enable Transit secrets engine:**
   ```bash
   vault secrets enable transit
   ```

2. **Create encryption key:**
   ```bash
   vault write -f transit/keys/archerdb type=aes256-gcm256
   ```

3. **Configure ArcherDB:**
   ```bash
   export VAULT_ADDR="https://vault.example.com:8200"
   export VAULT_TOKEN="s.xxxxx"

   archerdb start \
     --encryption-enabled=true \
     --encryption-key-provider=vault \
     --encryption-key-id=archerdb
   ```

## Key Storage Options

| Provider | Use Case | Security | Availability |
|----------|----------|----------|--------------|
| AWS KMS | Production AWS | HSM-backed | 99.999% |
| HashiCorp Vault | Multi-cloud | HSM optional | Self-managed |
| File | Development | Filesystem | Local |
| Environment | CI/CD | Process | In-memory |

### File-Based Key (Development Only)

**WARNING:** File-based keys are NOT recommended for production.

```bash
# Generate key
openssl rand -out /path/to/key.bin 32

# Set secure permissions
chmod 400 /path/to/key.bin
chown archerdb:archerdb /path/to/key.bin

# Configure
--encryption-key-provider=file
--encryption-key-path=/path/to/key.bin
```

### Environment Variable (CI/CD)

```bash
# Generate and export key (base64)
export ARCHERDB_ENCRYPTION_KEY=$(openssl rand -base64 32)

# Configure
--encryption-key-provider=env
--encryption-key-id=ARCHERDB_ENCRYPTION_KEY
```

### AWS KMS (Production)

```bash
# Configure
--encryption-key-provider=aws-kms
--encryption-key-id=arn:aws:kms:REGION:ACCOUNT:key/KEY-ID

# Optional: explicit region and credentials
--encryption-kms-region=us-east-1
# Uses IAM role by default, or set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
```

### HashiCorp Vault (Production)

```bash
# Configure
--encryption-key-provider=vault
--encryption-key-id=my-key-name

# Optional settings
--encryption-vault-addr=https://vault.example.com:8200
--encryption-vault-mount=transit
--encryption-vault-namespace=my-namespace

# Authentication: VAULT_TOKEN env var or AppRole
--encryption-vault-role-id=xxx
--encryption-vault-secret-id=xxx
```

## Algorithm Selection

### Decision Matrix

| Requirement | AES-256-GCM (v1) | Aegis-256 (v2) |
|-------------|------------------|----------------|
| FIPS 140-2 certification | Required | Not certified* |
| Maximum performance | Secondary | Primary |
| Hardware: AES-NI | Required | Required |
| Compliance: HIPAA | Accepted | Accepted |
| Compliance: PCI-DSS | Accepted | Accepted |
| Compliance: SOC 2 | Accepted | Accepted |

*Aegis-256 is under IETF standardization (draft-irtf-cfrg-aegis-aead). For strict FIPS requirements, use AES-256-GCM.

### Performance Comparison

| Algorithm | Throughput (AES-NI) | Latency | Auth Tag |
|-----------|---------------------|---------|----------|
| Aegis-256 | 5-10 GB/s | ~0.1 us/block | 128-bit |
| AES-256-GCM | 2-4 GB/s | ~0.3 us/block | 128-bit |

**Recommendation:** Use Aegis-256 (default) unless FIPS certification is required.

### Forcing Algorithm Version

```bash
# Force AES-256-GCM (v1) for FIPS compliance
--encryption-version=1

# Use Aegis-256 (v2) for maximum performance
--encryption-version=2  # default
```

## Key Rotation

Regular key rotation limits the exposure of encrypted data if a key is compromised.

### Rotation Frequency Recommendations

| Environment | Frequency | Rationale |
|-------------|-----------|-----------|
| Development | Never | Ephemeral data |
| Staging | Quarterly | Test procedures |
| Production | Annually | Balance security/operations |
| After breach | Immediately | Contain exposure |

### Rotation Procedure (File Key)

```bash
# Step 1: Verify current key
./scripts/key_rotation.sh \
  --key-type=file \
  --key-path=/etc/archerdb/key.bin \
  --verify

# Step 2: Dry-run rotation
./scripts/key_rotation.sh \
  --key-type=file \
  --key-path=/etc/archerdb/key.bin \
  --dry-run

# Step 3: Execute rotation
./scripts/key_rotation.sh \
  --key-type=file \
  --key-path=/etc/archerdb/key.bin \
  --backup-dir=/var/backups/archerdb-keys

# Step 4: Verify new key
archerdb verify --encryption /var/lib/archerdb/data/*.archerdb
```

### Rotation Procedure (AWS KMS)

```bash
# KMS handles key material rotation automatically
# Enable automatic rotation (annual)
aws kms enable-key-rotation --key-id arn:aws:kms:...

# Trigger immediate rotation
aws kms rotate-key-on-demand --key-id arn:aws:kms:...

# Verify rotation
./scripts/key_rotation.sh \
  --key-type=kms \
  --key-arn=arn:aws:kms:... \
  --verify
```

### Rotation Procedure (Vault)

```bash
# Rotate key material
vault write -f transit/keys/archerdb/rotate

# Verify new version
vault read transit/keys/archerdb

# Optional: Re-wrap existing DEKs with new key version
vault write transit/rewrap/archerdb \
  ciphertext="vault:v1:..."
```

## Emergency Key Revocation

If a key is compromised, follow these steps immediately:

### 1. Isolate Affected Systems (0-15 minutes)

```bash
# Stop ArcherDB to prevent further encryption operations
systemctl stop archerdb

# Revoke network access to key management system
# (implementation depends on your infrastructure)
```

### 2. Revoke Compromised Key (15-30 minutes)

**AWS KMS:**
```bash
# Schedule key deletion (7-30 day waiting period)
aws kms schedule-key-deletion \
  --key-id arn:aws:kms:... \
  --pending-window-in-days 7

# Disable key immediately
aws kms disable-key --key-id arn:aws:kms:...
```

**HashiCorp Vault:**
```bash
# Set minimum decryption version (prevents old versions)
vault write transit/keys/archerdb/config \
  min_decryption_version=NEW_VERSION \
  deletion_allowed=true

# Or delete key entirely
vault delete transit/keys/archerdb
```

**File-based:**
```bash
# Securely overwrite key file
shred -vfz -n 5 /etc/archerdb/key.bin
rm /etc/archerdb/key.bin
```

### 3. Generate New Key (30-60 minutes)

```bash
# Create new key in key management system
# (see Getting Started sections above)

# Update ArcherDB configuration with new key reference
```

### 4. Re-encrypt Data (1-24 hours)

```bash
# Export data with old key (if still accessible)
archerdb export \
  --encryption-key=OLD_KEY \
  --output=/backup/data.export

# Import with new key
archerdb import \
  --encryption-key=NEW_KEY \
  --input=/backup/data.export
```

### 5. Audit and Document (24-72 hours)

- Review access logs for key management system
- Identify scope of potential data exposure
- Document incident timeline and response
- Update procedures based on lessons learned

## Verification

### Verify Encryption is Enabled

```bash
# Check server status
archerdb status
# Output includes: "Encryption: enabled (v2)"

# Check specific data file
archerdb verify --encryption /var/lib/archerdb/data/0_0.archerdb
```

### Verify Key Health

```bash
# File key
./scripts/key_rotation.sh --key-type=file --key-path=... --verify

# AWS KMS
./scripts/key_rotation.sh --key-type=kms --key-arn=... --verify

# Vault
./scripts/key_rotation.sh --key-type=vault --vault-addr=... --key-name=... --verify
```

### Health Endpoint

```bash
curl http://localhost:8080/health/encryption
```

Response:
```json
{
  "enabled": true,
  "algorithm": "aegis-256",
  "version": 2,
  "key_provider": "aws-kms",
  "key_id_hash": "a1b2c3...",
  "hardware_accelerated": true
}
```

## Troubleshooting

### Error: AesNiNotAvailable

**Symptom:** Server fails to start with error code 206 (AesNiNotAvailable)

**Cause:** CPU does not support AES-NI hardware acceleration

**Solutions:**
1. Use a CPU with AES-NI support (recommended)
2. Enable software fallback (not recommended for production):
   ```bash
   --allow-software-crypto=true
   ```

### Error: KeyUnavailable (410)

**Symptom:** Encryption operations fail with error code 410

**Causes:**
- Key management system unreachable
- Invalid credentials
- Key deleted or disabled

**Solutions:**
1. Check network connectivity to KMS/Vault
2. Verify IAM permissions or Vault token
3. Check key status in management system

### Error: DecryptionFailed (411)

**Symptom:** Cannot read encrypted data files, error code 411

**Causes:**
- Wrong key used
- Data corruption
- Key rotation completed mid-operation

**Solutions:**
1. Verify correct key is configured
2. Check file integrity: `archerdb verify --checksum FILE`
3. If key was rotated, ensure all replicas use new key

### Error: KeyRotationInProgress (413)

**Symptom:** Write operations fail during key rotation

**Cause:** Key rotation is in progress

**Solution:** Wait for rotation to complete, then retry

### Performance Lower Than Expected

**Symptom:** Encryption throughput below 3 GB/s

**Causes:**
- Software fallback active
- CPU frequency scaling
- Memory bandwidth limitation

**Solutions:**
1. Verify AES-NI is detected: check logs for "Hardware AES-NI acceleration: AVAILABLE"
2. Disable CPU frequency scaling: `cpupower frequency-set -g performance`
3. Use faster memory or optimize memory access patterns

## Configuration Reference

| Flag | Description | Default |
|------|-------------|---------|
| `--encryption-enabled` | Enable encryption at rest | false |
| `--encryption-key-provider` | Key provider: file, env, aws-kms, vault | (required) |
| `--encryption-key-id` | Key identifier (ARN, path, or name) | (required) |
| `--encryption-key-path` | Path to key file (file provider) | - |
| `--encryption-version` | Algorithm version: 1 (GCM) or 2 (Aegis) | 2 |
| `--allow-software-crypto` | Allow software fallback | false |
| `--encryption-cache-ttl` | KEK cache TTL in seconds | 3600 |

## Related Documentation

- [Encryption Security Appendix](./encryption-security.md) - Threat model, compliance, algorithms
- [Operations Runbook](./operations-runbook.md) - Day-to-day operational procedures
- [Disaster Recovery](./disaster-recovery.md) - Backup and recovery with encryption
