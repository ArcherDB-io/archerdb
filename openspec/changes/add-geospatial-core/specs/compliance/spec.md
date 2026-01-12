# Compliance and Regulatory Specification

This specification defines ArcherDB's compliance requirements, particularly focusing on location data privacy, GDPR compliance, and regulatory obligations for geospatial applications.

---

## ADDED Requirements

### Requirement: GDPR Compliance for Location Data

The system SHALL comply with GDPR requirements for processing personal location data, treating location information as personal data.

#### Scenario: Location data as personal data

- **WHEN** handling location information
- **THEN** location data SHALL be treated as personal data under GDPR Article 4(1):
  - Location coordinates identify or are identifiable to natural persons
  - Location data reveals movement patterns and habits
  - Location data can be combined with other data for identification
  - Historical location data has long-term privacy implications
- **AND** GDPR compliance SHALL be documented and verified

#### Scenario: Lawful basis for processing

- **WHEN** processing location data
- **THEN** processing SHALL have lawful basis under GDPR Article 6:
  - **Consent:** Explicit user consent for location tracking
  - **Contract:** Location data necessary for service provision
  - **Legitimate Interest:** Balanced against individual rights
  - **Legal Obligation:** Required by law (emergency services)
- **AND** lawful basis SHALL be documented and auditable

### Requirement: Data Subject Rights Implementation

The system SHALL implement all GDPR data subject rights for location data processing.

#### Scenario: Right to access (Article 15)

- **WHEN** implementing data access rights
- **THEN** users SHALL be able to:
  - Request all location data held about them
  - Receive data in portable, machine-readable format
  - Access processing purpose and legal basis
  - Understand data retention periods
- **AND** access requests SHALL be fulfilled within 30 days

#### Scenario: Right to rectification (Article 16)

- **WHEN** implementing data correction rights
- **THEN** users SHALL be able to:
  - Correct inaccurate location data
  - Complete incomplete location records
  - Update outdated location information
  - Rectify location data processing context
- **AND** rectification SHALL be implemented securely

#### Scenario: Right to erasure (Article 17)

- **WHEN** implementing right to be forgotten
- **THEN** users SHALL be able to:
  - Request complete deletion of location data
  - Delete data across all replicas and backups
  - Remove data from audit logs where possible
  - Verify complete data erasure
- **AND** erasure SHALL be permanent and irreversible

#### Scenario: GDPR Deletion Edge Cases (Implementation Complexity)

- **WHEN** implementing entity deletion across a distributed cluster
- **THEN** the system SHALL handle these critical edge cases:

  **Case 1: Concurrent Delete Requests**
  - **Situation**: Multiple delete requests for same entity arrive simultaneously (e.g., GDPR request + user-initiated + legal hold override)
  - **Requirement**: All delete requests SHALL be serialized through VSR consensus
    - Primary assigns monotonic timestamp to each delete request
    - All replicas execute deletes in same order (deterministic)
  - **Implementation**: Use `entity_id` as key in LSM; each delete is new tombstone with higher timestamp
  - **Testing**: Fire 10+ concurrent delete requests for same entity; verify single tombstone created with highest timestamp
  - **Metric**: `archerdb_concurrent_deletes_merged` counter

  **Case 2: Partial Failure During Deletion (Network Partition)**
  - **Situation**: Primary creates tombstone, commits to WAL, but partition occurs before all replicas ack
    - Primary: Tombstone committed, returns success to client
    - Replica A: Received tombstone during catch-up
    - Replica B: Offline during partition, missed tombstone
  - **Requirement**: Eventual consistency via VSR view change
    - When Replica B rejoin cluster, VSR catch-up replays all committed operations including tombstone
    - Replica B applies same tombstone deterministically
  - **Implementation**: No special handling needed (VSR handles automatically)
  - **Testing**: Kill replica during delete, rejoin after partition heals, verify tombstone applied
  - **Metric**: `archerdb_deletion_view_change_recoveries` counter

  **Case 3: Post-Deletion Reinsertion (Timestamp Edge Case)**
  - **Situation**: Entity deleted, then user re-tracks immediately (within ~100μs), new location event arrives during delete WAL entry being replicated
    - Delete tombstone ID: `[S2_cell=X | timestamp=T_delete]`
    - New event ID: `[S2_cell=Y | timestamp=T_new]`
    - If `T_new < T_delete` (clock skew): Old location appears after deletion tombstone in LSM
    - If `T_new > T_delete` (normal): New location overrides deletion
  - **Requirement**: LWW semantics SHALL handle correctly
    - If reinserted timestamp > delete timestamp: New event is accepted (user re-tracking)
    - If reinserted timestamp < delete timestamp: Event is ignored (out-of-order, stale data from before deletion)
  - **Implementation**: Compare `T_new` vs `T_delete` during LSM compaction; skip stale events
  - **Testing**: Delete entity, immediately insert with synthetic earlier timestamp, verify not included in queries
  - **Risk**: If clock skew is large (>1s), older data could reappear; validate clock synchronization via Byzantine clock (Marzullo's algorithm per ArcherDB)
  - **Metric**: `archerdb_deletion_out_of_order_reinsertion` counter

  **Case 4: Tombstone Retention During Compaction (Compliance Window)**
  - **Situation**: Compaction runs while tombstones exist; when to actually delete tombstones?
    - Option A: Delete immediately (risky - audit trail needed, data recovery impossible)
    - Option B: Retain until all older versions eliminated (safe)
  - **Requirement**: SHALL retain tombstones until newer LSM levels confirm no older versions exist
    - Tombstone created at LSM compaction: Level = 0
    - During L0→L1 compaction: Check if older versions exist in L1+
    - If yes: Keep tombstone; if no: Mark for deletion (still retain 7 years for audit)
    - Metric: Track tombstone age and count
  - **Implementation**: Compaction iterator skips deleted versions; marks tombstone `ready_for_audit_archival` but doesn't delete file blocks until 7-year hold expires
  - **Testing**: Compact, verify tombstones preserved; check audit log retention
  - **Exit Criteria**: `archerdb_tombstone_elimination_count` tracks compactions that eliminated tombstones
  - **Metric**: `archerdb_tombstone_age_seconds` histogram (when deleted)

  **Case 5: In-Flight Queries (Race Condition)**
  - **Situation**: Query begins execution, entity is deleted mid-query
    - Thread 1: `find_in_radius(0, 0, 1000m)` starts, reads entity from LSM
    - Thread 2: `delete_entity(entity_id)` commits tombstone
    - Thread 1: Returns deleted entity in results (GDPR violation!)
  - **Requirement**: Queries SHALL use consensus timestamp for TTL checks; also apply to deletion tombstones
    - Query starts with `consensus_timestamp = T_query`
    - Check LSM: If any delete tombstone with `timestamp <= T_query`, skip result
    - Even if physical LSM block read the event, logical filter removes it
  - **Implementation**: Query engine applies `is_deleted(entity_id, consensus_timestamp)` check post-filter
  - **Testing**: Start long radius query, delete entity mid-query, verify not in final results
  - **Metric**: `archerdb_query_deleted_results_filtered` counter (should be 0 in normal operation)

  **Case 6: Deletion with TTL Overlap (Conflicting Expiration)**
  - **Situation**: TTL expiration vs explicit deletion race
    - Entity has `ttl_seconds=3600` (1 hour)
    - GDPR delete requested at 55 minutes
    - TTL background scanner expires at 60 minutes
  - **Requirement**: First event to commit wins (timestamp-based precedence)
    - If delete comes first: Tombstone with `T_delete` created
    - TTL scanner sees tombstone, skips (deletion already occurred)
    - If TTL expires first: TTL generates tombstone with `T_ttl`
    - Delete request compares timestamps, realizes entity already deleted
  - **Implementation**: No special handling; TTL and deletion both create tombstones (idempotent)
  - **Testing**: Create entity with 5s TTL, delete at 3s, verify exactly 1 tombstone
  - **Metric**: `archerdb_deletion_ttl_race_events` counter

#### Scenario: Right to data portability (Article 20)

- **WHEN** implementing data portability
- **THEN** users SHALL be able to:
  - Export location data in structured, machine-readable format
  - Transfer data to another controller
  - Receive data without hindrance
  - Access raw location coordinates and metadata
- **AND** portability SHALL include all location history

### Requirement: Privacy by Design Implementation

The system SHALL implement privacy by design principles throughout the architecture.

#### Scenario: Data minimization

- **WHEN** designing data collection
- **THEN** location data SHALL be minimized:
  - Only collect location data with explicit purpose
  - Store minimum required precision for use case
  - Implement automatic data expiration (TTL)
  - Avoid collecting unnecessary metadata
- **AND** data minimization SHALL be documented in privacy policy

#### Scenario: Purpose limitation

- **WHEN** processing location data
- **THEN** data SHALL be used only for specified purposes:
  - Location data SHALL NOT be repurposed without consent
  - Processing SHALL be limited to original collection purpose
  - Further processing SHALL require new lawful basis
  - Purpose changes SHALL be communicated to users
- **AND** purpose limitation SHALL be enforced technically

#### Scenario: Storage limitation

- **WHEN** storing location data
- **THEN** data SHALL have defined retention periods:
  - Default TTL based on use case requirements
  - User-configurable retention periods
  - Automatic expiration and deletion
  - Legal hold capabilities for investigations
- **AND** storage limitation SHALL be auditable

### Requirement: Consent Management

The system SHALL implement comprehensive consent management for location data collection.

#### Scenario: Consent collection

- **WHEN** collecting location data
- **THEN** consent SHALL be:
  - Freely given, specific, informed, and unambiguous
  - Separate from other terms and conditions
  - Documented and provable
  - Easily withdrawable at any time
  - Granular (different purposes, different consent)
- **AND** consent SHALL be obtained before location tracking begins

#### Scenario: Consent withdrawal

- **WHEN** users withdraw consent
- **THEN** system SHALL:
  - Immediately stop location data collection
  - Delete existing location data (right to erasure)
  - Communicate withdrawal to all processing parties
  - Document withdrawal for compliance records
  - Prevent future location data processing
- **AND** withdrawal SHALL be as easy as giving consent

### Requirement: Data Protection Impact Assessment

The system SHALL conduct and maintain Data Protection Impact Assessment (DPIA) for high-risk location data processing.

#### Scenario: DPIA requirements

- **WHEN** processing location data
- **THEN** DPIA SHALL assess:
  - Necessity and proportionality of processing
  - Risks to individual rights and freedoms
  - Safeguards and mitigation measures
  - Legitimate interests balancing test
  - Data protection by design implementation
- **AND** DPIA SHALL be reviewed annually or when processing changes

#### Scenario: High-risk determination

- **WHEN** evaluating processing risk
- **THEN** location data SHALL be considered high-risk due to:
  - Large-scale systematic monitoring
  - Sensitive data (movement patterns reveal private life)
  - Automated decision-making based on location
  - Cross-border data transfers
  - Invisible processing (users unaware of tracking)
- **AND** high-risk classification SHALL trigger enhanced protections

### Requirement: International Data Transfers

The system SHALL comply with GDPR requirements for international location data transfers.

#### Scenario: Cross-border transfer safeguards

- **WHEN** transferring location data internationally
- **THEN** transfers SHALL use adequate safeguards:
  - EU Commission adequacy decisions
  - Standard contractual clauses
  - Binding corporate rules
  - Certification mechanisms
  - Ad hoc contractual clauses
- **AND** transfer mechanisms SHALL be documented and auditable

#### Scenario: Data residency controls

- **WHEN** implementing data residency
- **THEN** system SHALL support:
  - Regional data isolation
  - Geographic data placement controls
  - Cross-region replication restrictions
  - Data sovereignty compliance
  - Local data processing requirements
- **AND** residency controls SHALL be configurable per deployment

### Requirement: Security Measures for Location Data

The system SHALL implement enhanced security measures appropriate for sensitive location data.

#### Scenario: Encryption at rest and in transit

- **WHEN** protecting location data
- **THEN** encryption SHALL be implemented:
  - End-to-end encryption for data in transit
  - AES-256 encryption for data at rest
  - Key rotation and management procedures
  - Secure key storage and access controls
  - Encryption key backup and recovery
- **AND** encryption SHALL use FIPS-compliant algorithms

#### Scenario: Access controls and audit

- **WHEN** controlling location data access
- **THEN** system SHALL implement:
  - Role-based access control (RBAC)
  - Multi-factor authentication for administrators
  - Comprehensive audit logging
  - Access pattern monitoring and alerting
  - Least privilege principle enforcement
- **AND** access SHALL be logged for compliance auditing

### Requirement: Breach Notification Procedures

The system SHALL implement GDPR-compliant breach notification procedures for location data breaches.

#### Scenario: Breach detection and assessment

- **WHEN** detecting potential breaches
- **THEN** system SHALL:
  - Monitor for unauthorized access patterns
  - Detect data exfiltration attempts
  - Identify location data exposure incidents
  - Assess breach risk and impact
  - Document breach investigation process
- **AND** breach detection SHALL be automated where possible

#### Scenario: Breach notification

- **WHEN** confirming a breach
- **THEN** notification SHALL be made:
  - To supervisory authority within 72 hours
  - To affected individuals without undue delay
  - In clear and understandable language
  - Including breach nature, consequences, and mitigation
  - With contact information for further assistance
- **AND** notification SHALL be documented and retained

### Requirement: Data Protection Officer Coordination

The system SHALL support coordination with Data Protection Officers (DPO) for GDPR compliance.

#### Scenario: DPO consultation interface

- **WHEN** implementing privacy features
- **THEN** system SHALL provide:
  - DPO consultation mechanisms
  - Privacy impact assessment tools
  - Compliance documentation templates
  - Audit trail access for DPOs
  - Regular compliance reporting
- **AND** DPO coordination SHALL be documented

#### Scenario: Privacy settings and controls

- **WHEN** implementing user controls
- **THEN** system SHALL provide:
  - Granular privacy preference settings
  - Easy consent withdrawal mechanisms
  - Transparent data processing information
  - Privacy dashboard for users
  - Data subject rights request portal
- **AND** privacy controls SHALL be user-friendly

### Requirement: Children's Location Data Protection

The system SHALL implement special protections for children's location data under GDPR Article 8.

#### Scenario: Age verification and consent

- **WHEN** processing children's location data
- **THEN** system SHALL:
  - Verify age before processing (16+ or parental consent)
  - Obtain parental consent for children under 16
  - Document consent mechanisms and verification
  - Implement stricter data minimization
  - Provide enhanced privacy protections
- **AND** children's data SHALL receive highest privacy protection

#### Scenario: Child-specific safeguards

- **WHEN** handling children's location data
- **THEN** processing SHALL include:
  - Purpose limitation to essential services only
  - Minimal data retention periods
  - Enhanced security measures
  - Restricted third-party sharing
  - Clear parental control mechanisms
- **AND** child protection SHALL be prioritized over functionality

### Requirement: Automated Decision Making Transparency

The system SHALL ensure transparency for automated decisions based on location data.

#### Scenario: Automated decision disclosure

- **WHEN** making automated decisions
- **THEN** system SHALL provide:
  - Clear explanation of decision logic
  - Location data factors considered
  - Decision-making criteria and weights
  - Right to human intervention
  - Right to contest automated decisions
- **AND** automated decisions SHALL be transparent and explainable

#### Scenario: Profiling safeguards

- **WHEN** creating location-based profiles
- **THEN** system SHALL implement:
  - Explicit consent for profiling
  - Clear profiling purpose disclosure
  - Right to object to profiling
  - Profile accuracy verification mechanisms
  - Profile deletion upon request
- **AND** profiling SHALL be opt-in with clear benefits

### Requirement: Vendor and Processor Compliance

The system SHALL ensure compliance when using third-party processors for location data.

#### Scenario: Processor selection and contracts

- **WHEN** engaging third-party processors
- **THEN** contracts SHALL include:
  - GDPR compliance obligations
  - Data processing purposes limitation
  - Security measure requirements
  - Audit and inspection rights
  - Breach notification obligations
  - Sub-processor approval requirements
- **AND** processor compliance SHALL be verified regularly

#### Scenario: Sub-processor management

- **WHEN** using sub-processors
- **THEN** system SHALL:
  - Maintain complete sub-processor list
  - Obtain user consent for sub-processor changes
  - Provide transparent sub-processor information
  - Ensure sub-processor GDPR compliance
  - Maintain audit rights over sub-processors
- **AND** sub-processor changes SHALL be communicated to users

### Requirement: Privacy Policy and Transparency

The system SHALL provide comprehensive privacy policy and transparency information.

#### Scenario: Privacy policy requirements

- **WHEN** creating privacy policy
- **THEN** policy SHALL include:
  - Clear identification of controller and processor
  - Detailed data processing purposes
  - Legal basis for each processing activity
  - Data subject rights and exercise procedures
  - Data retention periods and deletion procedures
  - International transfer information
  - Contact information for privacy inquiries
- **AND** privacy policy SHALL be written at ≤8th grade reading level (Flesch-Kincaid score ≥60) and accessible via public URL

#### Scenario: Transparency reporting

- **WHEN** providing transparency information
- **THEN** system SHALL disclose:
  - Data collection and processing activities
  - Data sharing practices and recipients
  - Automated decision-making processes
  - Risk assessments and safeguards
  - Compliance measures and certifications
  - Data protection impact assessments
- **AND** transparency SHALL be proactive and continuous

### Requirement: Compliance Monitoring and Auditing

The system SHALL implement continuous compliance monitoring and auditing capabilities.

#### Scenario: Compliance monitoring

- **WHEN** monitoring GDPR compliance
- **THEN** system SHALL track:
  - Consent validity and withdrawal rates
  - Data subject rights request fulfillment
  - Breach detection and response times
  - International transfer compliance
  - Data retention compliance
  - Privacy impact assessment updates
- **AND** compliance metrics SHALL be continuously monitored

#### Scenario: Audit trail maintenance

- **WHEN** maintaining audit trails
- **THEN** system SHALL preserve:
  - All data processing activities
  - Consent records and changes
  - Data subject rights requests and responses
  - Breach incidents and responses
  - DPIA assessments and updates
  - Compliance training records
- **AND** audit trails SHALL be tamper-proof (append-only, checksummed) and retained for minimum 7 years (GDPR Article 5.1.e, financial audit requirements)

### Requirement: Regulatory Reporting

The system SHALL support regulatory reporting requirements for location data processing.

#### Scenario: Supervisory authority coordination

- **WHEN** interacting with supervisory authorities
- **THEN** system SHALL provide:
  - Designated DPO contact information
  - Data processing records and documentation
  - Breach notification procedures
  - Compliance assessment results
  - Data protection impact assessments
  - Audit trail access and reports
- **AND** authority coordination SHALL be documented

#### Scenario: Compliance certifications

- **WHEN** pursuing compliance certifications
- **THEN** system SHALL support:
  - ISO 27001 information security certification
  - SOC 2 Type II compliance
  - GDPR compliance assessments
  - Privacy shield or similar frameworks
  - Industry-specific certifications
- **AND** certifications SHALL be maintained and renewed

### Related Specifications

- See `specs/security/spec.md` for data protection and encryption requirements
- See `specs/ttl-retention/spec.md` for GDPR right to erasure implementation
- See `specs/observability/spec.md` for audit logging and compliance monitoring



## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| GDPR Consent Management | ✓ Complete | \`consent_management.zig\` |
| Data Subject Rights | ✓ Complete | \`data_subject_rights.zig\` |
| Data Minimization | ✓ Complete | \`data_minimization.zig\` |
| Compliance Audit | ✓ Complete | \`compliance_audit.zig\` |
| Breach Notification | ✓ Complete | \`breach_notification.zig\` |
| DPIA Support | ✓ Complete | \`dpia.zig\` |
| Data Transfer | ✓ Complete | \`data_transfer.zig\` |
| Export Control | ✓ Complete | \`export_control.zig\` |
