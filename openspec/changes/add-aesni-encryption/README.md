# Hardware-Accelerated AES-NI Encryption

**Status**: Proposal
**Change ID**: `add-aesni-encryption`
**Target Version**: v2.1

## Quick Summary

Upgrade encryption from software AES-256-GCM to hardware-accelerated Aegis-256 with explicit AES-NI validation, startup checks, and observability metrics.

## Key Changes

| Aspect | v1 (Current) | v2 (Proposed) |
|--------|--------------|---------------|
| Cipher | AES-256-GCM | Aegis-256 |
| AES-NI | Silent fallback | Required (with bypass for testing) |
| Throughput | ~1.5 GB/s | >3 GB/s |
| Detection | None | Explicit at startup |
| Metrics | Operations only | + hardware status, throughput |

## New CLI Flag

```bash
# For testing in VMs without AES-NI (NOT for production)
archerdb start --allow-software-crypto=true
```

## New Metrics

```prometheus
archerdb_encryption_aesni_available 1      # Hardware available
archerdb_encryption_using_software 0       # Using software fallback
archerdb_encryption_cipher_version 2       # 1=GCM, 2=Aegis
archerdb_encryption_throughput_bytes{operation="encrypt"} 4294967296
```

## New Error Code

| Code | Name | Message |
|------|------|---------|
| 415 | aesni_not_available | AES-NI hardware acceleration required but not available |

## Backward Compatibility

- **Reads**: Can read both v1 (AES-GCM) and v2 (Aegis-256) files
- **Writes**: New files always use v2 (Aegis-256)
- **Migration**: Automatic during compaction (v1 → v2)

## Files

- `proposal.md` - Problem, scope, success criteria
- `design.md` - Architecture, decisions, trade-offs
- `tasks.md` - Implementation plan (~2-3 days)
- `specs/security/spec.md` - Cipher and hardware requirements
- `specs/observability/spec.md` - Hardware and performance metrics
- `specs/configuration/spec.md` - Software crypto bypass flag

## Review Checklist

- [x] Problem clearly stated
- [x] Design decisions documented
- [x] Spec deltas with scenarios
- [x] Implementation tasks broken down
- [x] Success criteria defined
- [x] Backward compatibility addressed

## Next Steps

1. Review proposal for approval
2. Implement according to tasks.md
3. Validate with performance benchmarks
4. Update hardware requirements documentation
