# ArcherDB Data Protection Security Model

This document defines ArcherDB's security boundary for data protection.

## Security Boundary

ArcherDB is designed for trusted-network deployment and assumes:

- Authentication and authorization are enforced before ArcherDB (gateway/service layer)
- Transport security is enforced outside ArcherDB (TLS termination/service mesh/private links)
- At-rest encryption is enforced by storage and cloud platform controls
- Backup confidentiality and retention are enforced by external backup tooling

## In Scope (ArcherDB)

- Replication safety and durability guarantees
- Deterministic recovery behavior (`recover`, replica sync)
- Operational guidance for private-network deployment

## Out of Scope (ArcherDB Product Surface)

- Native authn/authz provider implementation
- Native TLS/mTLS session management for client and replica traffic
- Native encryption-at-rest and key hierarchy lifecycle
- Native backup orchestration and encrypted archive lifecycle

## Required External Controls

For production deployments, implement:

- API gateway/service mesh policies for identity and authorization
- Network segmentation + firewall controls for DB ports
- Encrypted storage volumes and encrypted snapshot/object stores
- KMS/HSM-backed key governance and audit logging
- Backup/restore automation with periodic drill evidence

## Compliance Positioning

Compliance attestations (SOC 2, HIPAA, PCI) should map to platform and organizational controls around ArcherDB, not to built-in ArcherDB cryptographic/auth subsystems.

## Operator Checklist

- [ ] ArcherDB ports are private-only
- [ ] Security policy enforces external authn/authz at ingress
- [ ] Data and snapshot storage are encrypted by default
- [ ] Key management and key access auditing are enabled
- [ ] Restore drills are executed and documented

