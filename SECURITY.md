# Security Policy

This document describes how to report security vulnerabilities in ArcherDB and what to expect from the maintainers.

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |
| < 1.0   | :x: (pre-release)  |

Once ArcherDB reaches version 1.0, we will maintain security updates for the current major version and one prior major version.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

### How to Report

1. **GitHub Security Advisories (Preferred)**

   Use GitHub's private vulnerability reporting:
   - Go to [Security Advisories](https://github.com/ArcherDB-io/archerdb/security/advisories)
   - Click "Report a vulnerability"
   - Fill out the form with details

2. **Email**

   If you cannot use GitHub Security Advisories, email the maintainers directly. Contact information is available in the repository's maintainer list.

### What to Include

Please provide as much of the following information as possible:

- **Type of vulnerability** (e.g., buffer overflow, authentication bypass, data exposure)
- **Affected component** (e.g., consensus protocol, storage engine, network layer, client SDK)
- **Steps to reproduce** the vulnerability
- **Proof of concept** code or commands (if available)
- **Impact assessment** - what an attacker could achieve
- **Suggested fix** (if you have one)
- **Your contact information** for follow-up questions

### What to Expect

| Timeframe | Action |
|-----------|--------|
| 24 hours | Acknowledgment of your report |
| 72 hours | Initial assessment and severity rating |
| 7 days | Detailed response with remediation plan |
| 90 days | Target for fix release (may vary by severity) |

We follow coordinated disclosure practices:
- We will work with you to understand and validate the issue
- We will keep you informed of our progress
- We will credit you in the security advisory (unless you prefer anonymity)
- We ask that you give us reasonable time to address the issue before public disclosure

## Security Considerations

### Architecture Security

ArcherDB inherits ArcherDB's security-focused architecture:

- **Deterministic execution**: All operations are deterministic, reducing attack surface
- **No dynamic memory allocation**: Bounded resource usage prevents many memory-based attacks
- **Consensus-based replication**: Byzantine fault tolerance through VSR protocol

### Planned Security Features

The following security features are planned or in development:

- **mTLS**: Mutual TLS for all inter-node and client-server communication
- **Authentication**: Client certificate validation
- **Encryption at rest**: Data file encryption (planned)

### Deployment Security

When deploying ArcherDB:

1. **Network isolation**: Run cluster nodes on a private network
2. **Firewall rules**: Restrict access to cluster ports
3. **File permissions**: Protect data files with appropriate permissions
4. **Regular updates**: Keep ArcherDB updated to receive security fixes

## Scope

### In Scope

- ArcherDB server (`archerdb` binary)
- Official client SDKs (when released)
- Build and deployment tooling
- Documentation that could lead to insecure configurations

### Out of Scope

- Vulnerabilities in dependencies that don't affect ArcherDB
- Social engineering attacks
- Physical attacks on infrastructure
- Denial of service through expected resource limits
- Issues in third-party integrations not maintained by ArcherDB

## Recognition

We appreciate the security research community's efforts in helping keep ArcherDB secure. Contributors who report valid security issues will be:

- Credited in the security advisory (with permission)
- Listed in our security acknowledgments
- Thanked publicly (with permission)

## Upstream Security

ArcherDB is a derivative of [ArcherDB](https://archerdb.com/). Security issues that affect the core consensus protocol or storage engine may also affect ArcherDB. We coordinate with the ArcherDB team on shared security concerns.

If you discover a vulnerability that may affect ArcherDB, please also consider reporting it to them through their security channels.

## Updates to This Policy

This security policy may be updated periodically. Check this document for the latest guidance on reporting security issues.

---

*Thank you for helping keep ArcherDB and its users safe.*
