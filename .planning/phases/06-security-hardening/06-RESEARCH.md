# Phase 6: Security Hardening - Research

**Researched:** 2026-01-31
**Domain:** Security controls documentation, skip policy, existing security infrastructure
**Confidence:** HIGH

## Summary

This phase has a unique situation: **ALL security requirements (SEC-01 through SEC-10) are being SKIPPED** due to a local-only deployment assumption. Rather than implementing security controls, this phase becomes a documentation and verification pass to formally acknowledge the scope reduction while documenting what security infrastructure already exists in the codebase.

The research reveals that ArcherDB has **substantial security infrastructure already implemented** - just not being activated for this deployment scenario:

1. **Encryption at rest** - Full implementation in `src/encryption.zig` with Aegis-256/AES-256-GCM, KMS integration, key rotation
2. **TLS infrastructure** - mTLS support in `src/archerdb/tls_config.zig` and `src/archerdb/replica_tls.zig` with certificate revocation checking
3. **Compliance audit logging** - GDPR-compliant audit trail in `src/archerdb/compliance_audit.zig`
4. **Extensive documentation** - `docs/encryption-guide.md` and `docs/encryption-security.md` cover threat models, compliance mapping

**Primary recommendation:** Document the skip decisions formally in ROADMAP.md and REQUIREMENTS.md using a new status "SKIPPED" (distinct from "NOT_TESTED"). Verify that existing security capabilities are documented even if not being deployed. Create a minimal verification plan that confirms the skip decisions are appropriate for the local-only deployment assumption.

## Context: Why Security is Being Skipped

Per the CONTEXT.md decisions:

| Category | Decision | Rationale |
|----------|----------|-----------|
| Authentication | No authentication | Local-only access assumed |
| Authorization | No access control | All connections have full access |
| TLS (client) | Plaintext | Safe on localhost |
| TLS (replica) | Plaintext | Trusted network assumed |
| Encryption at rest | None | Rely on OS/disk-level encryption |
| Audit logging | Existing logs sufficient | No separate audit trail needed |

**Critical Assumption:** This is a local-only deployment where:
- The database is not exposed to untrusted networks
- All clients are on the same machine or trusted network segment
- Physical and OS-level security controls are in place

## Documenting Skipped Requirements

### Recommended Status Taxonomy

Based on how Phase 5 handled requirements that couldn't be tested:

| Status | Meaning | Use Case |
|--------|---------|----------|
| `PASS` | Requirement met with evidence | Normal completion |
| `PARTIAL` | Partially met (e.g., 77% of target) | Measurable partial achievement |
| `NOT_TESTED` | Could not test due to infrastructure limitations | Want to test but can't |
| `SKIPPED` | **Intentionally not implemented per scope decision** | Conscious scope reduction |
| `DEFERRED` | Moved to future phase/version | Planned for later |

**Key distinction:** `NOT_TESTED` = "want to test but can't", `SKIPPED` = "chose not to implement"

### How to Update REQUIREMENTS.md

Current Phase 6 entries show requirements as "Pending":
```markdown
| SEC-01 | Phase 6 | Pending |
```

Recommended change:
```markdown
| SEC-01 | Phase 6 | SKIPPED (local-only) |
```

### How to Update ROADMAP.md

Current success criteria assume implementation:
```markdown
**Success Criteria** (what must be TRUE):
  1. Unauthenticated client connections are rejected
  2. Authorization controls prevent unauthorized entity access
  ...
```

Recommended change:
```markdown
**Success Criteria** (what must be TRUE):
  1. Skip decisions are documented with risk acknowledgment
  2. Existing security infrastructure is documented
  3. Assumptions for safe local-only deployment are recorded
```

## Existing Security Infrastructure

### Encryption at Rest (SEC-05 capability exists)

**Location:** `src/encryption.zig` (1000+ lines)

| Feature | Implementation | Status |
|---------|----------------|--------|
| Algorithm | Aegis-256 (v2, default), AES-256-GCM (v1) | Complete |
| Key Management | AWS KMS, HashiCorp Vault, file-based, env var | Complete |
| Key Wrapping | AES-256-GCM wrapped DEKs | Complete |
| Hardware Accel | AES-NI detection and requirement | Complete |
| File Format | 96-byte header with wrapped DEK | Complete |

**Documentation:** `docs/encryption-guide.md`, `docs/encryption-security.md`

**Not being deployed because:** Local-only assumption relies on OS/disk-level encryption

### TLS Infrastructure (SEC-03, SEC-04 capability exists)

**Location:** `src/archerdb/tls_config.zig` (1100+ lines), `src/archerdb/replica_tls.zig` (350+ lines)

| Feature | Implementation | Status |
|---------|----------------|--------|
| mTLS for clients | Certificate path validation, PEM parsing | Complete |
| mTLS for replicas | Replica ID extraction from CN | Complete |
| CRL checking | Local CRL file support | Complete |
| OCSP checking | Basic OCSP request/response | Partial |
| Certificate reload | SIGHUP-based hot reload | Complete |
| Revocation modes | fail-closed, fail-open policies | Complete |

**Limitations noted in code:**
- Zig std library only provides TLS client, not server
- Full mTLS requires FFI to OpenSSL/BoringSSL or custom TLS 1.3 implementation

**Not being deployed because:** Localhost/trusted network assumed safe for plaintext

### Audit Logging (SEC-07 capability exists)

**Location:** `src/archerdb/compliance_audit.zig`

| Feature | Implementation | Status |
|---------|----------------|--------|
| Entry types | 16 types (data_processing, consent_change, etc.) | Complete |
| Categories | data_activity, consent, subject_rights, breach, administration, security | Complete |
| Retention | 7-year retention per GDPR Article 5.1.e | Complete |
| Cryptographic integrity | SHA256 checksums | Complete |

**Not being deployed because:** Existing structured logs deemed sufficient

### Existing Logging

The database has comprehensive structured logging via `std.log.scoped(...)` throughout the codebase:
- Operation logging in geo_state_machine.zig
- Network events in connection_pool.zig
- VSR consensus events in vsr/replica.zig

## Minimal Phase Work

Given all security requirements are SKIPPED, the phase should:

### 1. Document Skip Decisions Formally

Create a verification document that explicitly acknowledges:
- Each requirement being skipped
- The rationale (local-only deployment)
- The assumptions that must hold
- The risk implications

### 2. Document Existing Security Infrastructure

Create an inventory of security capabilities that exist but are not deployed:
- Encryption at rest: Full capability, not enabled
- TLS: Infrastructure exists, not configured
- Audit logging: GDPR-compliant system exists, using default logs instead

### 3. Record Assumptions

Document the assumptions that make skipping acceptable:
- Database not exposed to untrusted networks
- Physical security of the deployment environment
- OS-level security controls (firewall, disk encryption, access controls)
- All clients are trusted

### 4. Create Risk Acknowledgment

Document what risks exist due to skipping:
- Network sniffing could expose data in transit
- No authentication means any client can connect
- No audit trail for security forensics
- Data at rest not encrypted by database layer

## Architecture Patterns

### Skip Documentation Pattern

```markdown
## Requirement: SEC-XX - [Title]

**Status:** SKIPPED
**Rationale:** [Why this is acceptable]
**Assumptions:**
- [Assumption 1 that must hold]
- [Assumption 2]
**Risk if assumption violated:** [Impact]
**Existing capability:** [What already exists if applicable]
```

### Verification Report Structure

```markdown
---
phase: 06-security-hardening
status: SKIPPED (all requirements)
verified: YYYY-MM-DD
---

# Phase 6: Security Hardening Verification

## Scope Decision

All SEC requirements intentionally skipped for local-only deployment.

## Requirements Status

| Requirement | Status | Capability Exists | Notes |
|-------------|--------|-------------------|-------|
| SEC-01 | SKIPPED | No | No auth for local-only |
| SEC-02 | SKIPPED | No | No RBAC implemented |
| SEC-03 | SKIPPED | Yes | TLS infrastructure exists |
| SEC-04 | SKIPPED | Yes | mTLS replica code exists |
| SEC-05 | SKIPPED | Yes | Full encryption module exists |
| SEC-06 | SKIPPED | Yes | Key rotation documented |
| SEC-07 | SKIPPED | Yes | Compliance audit module exists |
| SEC-08 | SKIPPED | N/A | External requirement |
| SEC-09 | SKIPPED | No | CI/CD scanning not implemented |
| SEC-10 | SKIPPED | No | CVE scanning not implemented |

## Assumptions for Safe Operation

[List assumptions]

## Risk Acknowledgment

[Document risks]

## Existing Security Documentation

- docs/encryption-guide.md
- docs/encryption-security.md
- SECURITY.md (vulnerability reporting)

## Conclusion

Phase 6 goals ACHIEVED via intentional scope reduction.
All skip decisions documented with risk acknowledgment.
```

## Don't Hand-Roll

For this phase specifically:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Security status tracking | New status system | Extend existing PASS/FAIL/NOT_TESTED | Consistency with other phases |
| Risk documentation | Custom format | Standard markdown tables | Simplicity, readability |
| Capability inventory | New inventory system | Reference existing source files | Source of truth is code |

## Common Pitfalls

### Pitfall 1: Confusing SKIPPED with NOT_TESTED

**What goes wrong:** Using NOT_TESTED for intentionally skipped requirements
**Why it happens:** Both mean "not implemented" but have different implications
**How to avoid:** NOT_TESTED = infrastructure limitation; SKIPPED = scope decision
**Warning signs:** Verification report suggests "test later" for skipped items

### Pitfall 2: Undocumented Assumptions

**What goes wrong:** Skip decisions without explicit assumptions listed
**Why it happens:** Assumptions seem "obvious" during planning
**How to avoid:** Every SKIPPED requirement must list assumptions that make it acceptable
**Warning signs:** Future reader can't determine when to re-enable security

### Pitfall 3: Forgetting Existing Capabilities

**What goes wrong:** Skip documentation doesn't mention that capabilities exist
**Why it happens:** Focus on what's NOT being done vs what COULD be done
**How to avoid:** For each skipped requirement, note if capability already exists
**Warning signs:** Future phase thinks security needs to be built from scratch

### Pitfall 4: Incomplete Risk Documentation

**What goes wrong:** Risks not documented, leading to unsafe deployment assumptions
**Why it happens:** "We know it's local-only" isn't written down
**How to avoid:** Each risk must have explicit acknowledgment
**Warning signs:** Someone deploys to production without enabling security

## Code Examples

No code examples needed for this phase - it's documentation-focused.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Skip = don't document | Skip = document thoroughly | This project | Maintains traceability |
| Binary PASS/FAIL | PASS/PARTIAL/NOT_TESTED/SKIPPED | Phase 5+ | Better requirement status visibility |

## Open Questions

### 1. Should ROADMAP.md Phase 6 success criteria be rewritten?

**What we know:** Current criteria assume implementation
**What's unclear:** Whether to rewrite criteria or keep them with SKIPPED status
**Recommendation:** Rewrite criteria to reflect actual phase scope (documentation/verification)

### 2. Should skipped requirements affect "production readiness" assessment?

**What we know:** Security is typically required for production
**What's unclear:** Whether local-only deployment is considered "production ready"
**Recommendation:** Note in PROJECT.md that this is for local-only deployment only

### 3. What triggers future implementation?

**What we know:** Requirements are deferred, not abandoned
**What's unclear:** What conditions would trigger implementation
**Recommendation:** Document triggers (e.g., "if exposing to network", "if multi-tenant")

## Sources

### Primary (HIGH confidence)
- `/home/g/archerdb/src/encryption.zig` - Full encryption implementation
- `/home/g/archerdb/src/archerdb/tls_config.zig` - TLS configuration with CRL/OCSP
- `/home/g/archerdb/src/archerdb/replica_tls.zig` - Replica mTLS infrastructure
- `/home/g/archerdb/src/archerdb/compliance_audit.zig` - GDPR-compliant audit logging
- `/home/g/archerdb/docs/encryption-guide.md` - Comprehensive encryption documentation
- `/home/g/archerdb/docs/encryption-security.md` - Threat model, compliance mapping
- `/home/g/archerdb/.planning/phases/06-security-hardening/06-CONTEXT.md` - Skip decisions

### Secondary (MEDIUM confidence)
- `/home/g/archerdb/.planning/phases/05-performance-optimization/05-VERIFICATION.md` - Pattern for NOT_TESTED status
- `/home/g/archerdb/.planning/REQUIREMENTS.md` - Current requirement status tracking
- `/home/g/archerdb/.planning/ROADMAP.md` - Current phase structure

## Metadata

**Confidence breakdown:**
- Existing infrastructure: HIGH - Verified by reading source files
- Documentation patterns: HIGH - Based on Phase 5 precedent
- Risk assessment: MEDIUM - Assumptions documented in CONTEXT.md

**Research date:** 2026-01-31
**Valid until:** 2026-06-30 (stable - documentation phase)

---
*Research for Phase 6: Security Hardening*
*Focus: Skip documentation and existing capability inventory*
