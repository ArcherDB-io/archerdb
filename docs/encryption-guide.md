# ArcherDB Data Protection Guide

ArcherDB uses an infrastructure-managed protection model. Encryption at rest is enforced by your platform, not by ArcherDB server runtime flags.

## Scope

ArcherDB itself does not provide:

- Built-in page/file encryption configuration
- Built-in KMS/Vault key lifecycle orchestration
- Built-in key-rotation workflows

Use external controls for at-rest protection.

## Recommended Controls

### 1) Encrypt Storage Volumes

Use the native encryption mechanism of your environment:

- Cloud block volumes with provider-managed keys (KMS-backed)
- LUKS/FileVault/BitLocker for self-managed hosts
- Encrypted object storage for snapshots/archives

### 2) Centralize Key Management

Manage keys in dedicated key systems:

- Cloud KMS
- HSM-backed key services
- Vault-based key governance

### 3) Enforce Access Controls

- Restrict node and storage IAM roles
- Separate key administrators from DB operators
- Audit all key access and policy changes

### 4) Verify Encryption Continuously

- Validate encrypted volume settings in IaC/CI
- Alert on unencrypted volumes and buckets
- Run periodic restore drills from encrypted snapshots

## Example Verification Checklist

- [ ] Data volumes are encrypted by policy
- [ ] Snapshot/object storage encryption is enforced
- [ ] KMS key policies follow least privilege
- [ ] Key access logs are centralized and retained
- [ ] Restore drills include encrypted snapshot recovery

## Migration Note

Legacy references to ArcherDB-native encryption flags are deprecated in this documentation set. Treat encryption-at-rest as a platform requirement around ArcherDB.

