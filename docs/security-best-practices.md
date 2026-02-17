# Security Best Practices

This guide documents security best practices for securing your ArcherDB deployment in a local-only environment.

## Quick Security Checklist

Before deploying ArcherDB in production, verify:

- [ ] ArcherDB ports (3000-3002) not exposed to internet
- [ ] Data files have restricted permissions (600)
- [ ] Full disk encryption enabled on data volumes
- [ ] External snapshot/backup tooling configured with encrypted storage
- [ ] SSH access restricted to authorized users only
- [ ] Audit logging enabled for compliance requirements
- [ ] Firewall rules configured to block external access

## Deployment Model

ArcherDB is designed for local-only deployment where security is handled at the infrastructure level. This model assumes:

- Database runs on trusted internal networks (localhost or private VPC)
- All clients are trusted applications on the same infrastructure
- Physical and network security are managed at the infrastructure level
- No direct internet exposure of database ports

This guide focuses on infrastructure-level security controls appropriate for this deployment model.

## Network Security

### Firewall Configuration

Block external access to ArcherDB ports:

```bash
# UFW (Ubuntu/Debian)
sudo ufw deny from any to any port 3000:3002 proto tcp
sudo ufw allow from 127.0.0.1 to any port 3000:3002 proto tcp
sudo ufw allow from 10.0.0.0/8 to any port 3000:3002 proto tcp  # Internal network

# iptables
iptables -A INPUT -p tcp --dport 3000:3002 -s 127.0.0.1 -j ACCEPT
iptables -A INPUT -p tcp --dport 3000:3002 -s 10.0.0.0/8 -j ACCEPT
iptables -A INPUT -p tcp --dport 3000:3002 -j DROP
```

### Port Reference

| Port | Service | Access |
|------|---------|--------|
| 3000 | Client API | Internal only |
| 3001 | Replication | Internal only (between replicas) |
| 3002 | Control plane | Internal only |
| 9090 | Metrics (Prometheus) | Monitoring infrastructure only |

### VPC/Private Network Deployment

For cloud deployments:

1. **Deploy in private subnet**: No public IP assignment
2. **Use security groups**: Allow only internal CIDR ranges
3. **Network ACLs**: Block all inbound from 0.0.0.0/0 to database ports
4. **No NAT for database traffic**: Database should not initiate external connections

Example AWS security group:

```json
{
  "SecurityGroupIngress": [
    {
      "IpProtocol": "tcp",
      "FromPort": 3000,
      "ToPort": 3002,
      "SourceSecurityGroupId": "sg-app-servers"
    },
    {
      "IpProtocol": "tcp",
      "FromPort": 9090,
      "ToPort": 9090,
      "SourceSecurityGroupId": "sg-monitoring"
    }
  ]
}
```

### No Public Internet Exposure

ArcherDB should **never** be directly accessible from the public internet:

- No public IP addresses on database nodes
- No port forwarding from public load balancers
- No exposure through Kubernetes LoadBalancer services

If remote access is required for administration, use secure tunneling.

### SSH Tunneling for Remote Access

For remote administrative access, use SSH tunneling:

```bash
# From local machine, create tunnel to remote database
ssh -L 3001:localhost:3001 user@bastion.internal

# Then connect via localhost
archerdb-cli --address 127.0.0.1:3001
```

For development environments:

```bash
# Forward all ArcherDB ports
ssh -L 3000:localhost:3000 -L 3001:localhost:3001 -L 3002:localhost:3002 user@dev-server
```

## Disk Security

### Full Disk Encryption

Enable full disk encryption on all volumes containing ArcherDB data:

#### Linux (LUKS)

```bash
# Create encrypted volume (do this before writing data)
sudo cryptsetup luksFormat /dev/sdb
sudo cryptsetup luksOpen /dev/sdb archerdb_data
sudo mkfs.ext4 /dev/mapper/archerdb_data
sudo mount /dev/mapper/archerdb_data /var/lib/archerdb
```

#### macOS (FileVault)

Enable FileVault in System Preferences > Security & Privacy > FileVault.

#### Windows (BitLocker)

Enable BitLocker on the data volume via Settings > Privacy & security > Device encryption.

### File Permissions

Set restrictive permissions on ArcherDB data files:

```bash
# Data directory
chmod 700 /var/lib/archerdb
chown archerdb:archerdb /var/lib/archerdb

# Data files (set by ArcherDB, verify)
find /var/lib/archerdb -type f -exec chmod 600 {} \;

# Verify permissions
ls -la /var/lib/archerdb/
# Expected: -rw------- 1 archerdb archerdb
```

### Backup Encryption

Always encrypt backups at rest:

```bash
# Encrypt platform snapshot/export with GPG
tar -C /var/lib/archerdb -cf - . | gpg --symmetric --cipher-algo AES256 > archerdb-snapshot.tar.gpg

# Encrypt with age (modern alternative)
tar -C /var/lib/archerdb -cf - . | age -r age1... > archerdb-snapshot.tar.age
```

For automated backups, see [Backup Operations](./backup-operations.md) for integration with encrypted storage backends.

### Secure Deletion

When decommissioning storage:

```bash
# Overwrite data files before removal
shred -vfz -n 3 /var/lib/archerdb/*.db

# Or use secure erase on SSD
hdparm --user-master u --security-set-pass SECRET /dev/sdb
hdparm --user-master u --security-erase SECRET /dev/sdb
```

For cloud deployments, rely on provider's encryption and volume destruction procedures.

## Security Non-Goals (Product Surface)

ArcherDB intentionally does not treat the following controls as built-in server guarantees:

- Authentication / authorization
- TLS / mTLS transport security
- Native encryption-at-rest key management
- Managed backup orchestration

These controls should be enforced in surrounding infrastructure:

- API gateway/service mesh for authn/authz and TLS termination
- Private networking + firewall segmentation for east-west traffic
- Cloud/disk encryption and KMS policy controls for at-rest protection
- Platform backup tooling (volume snapshots, object-store replication, restore drills)

Use this model as the default for production hardening and compliance evidence.

## Operational Security

### Server Access Control

Restrict access to ArcherDB servers:

1. **SSH key-only authentication**: Disable password authentication
   ```bash
   # /etc/ssh/sshd_config
   PasswordAuthentication no
   PubkeyAuthentication yes
   ```

2. **Use jump boxes/bastion hosts**: No direct SSH to database servers
   ```bash
   # ~/.ssh/config
   Host archerdb-*
     ProxyJump bastion.internal
     User archerdb-admin
   ```

3. **Principle of least privilege**: Dedicated service account for ArcherDB
   ```bash
   # Create dedicated user
   useradd -r -s /bin/false archerdb
   ```

### Log Monitoring

Monitor logs for security events:

```bash
# Watch for connection attempts
tail -f /var/log/archerdb/archerdb.log | grep -i "connection\|auth\|error"

# Monitor system logs for OOM or permission issues
journalctl -u archerdb -f
```

Key events to monitor:
- Unexpected connection sources
- Repeated connection failures
- Permission denied errors
- Resource exhaustion warnings

### Regular Security Updates

Keep ArcherDB and system packages updated:

```bash
# Check for ArcherDB updates
archerdb --version

# Update system packages (schedule during maintenance windows)
sudo apt update && sudo apt upgrade

# Subscribe to security announcements
# https://github.com/ArcherDB-io/archerdb/security/advisories
```

### Backup Verification

Regularly verify backup integrity:

```bash
# Verify latest snapshot/archive can be restored (quarterly)
# Example: restore in staging and run smoke checks
./scripts/test-readiness-persistence.sh

# Test actual restore to staging environment (monthly)
# See disaster-recovery.md for full procedure
```

## Security Assumptions

This deployment model is appropriate **only if** these assumptions hold:

| Assumption | Verification |
|------------|--------------|
| Network isolation | Database ports not reachable from untrusted networks |
| Client trust | All connecting applications are vetted and trusted |
| Physical security | Server room/cloud account access is controlled |
| OS-level security | Firewall active, disk encryption enabled, patches applied |
| Single-tenant | No multi-tenant isolation requirements |

If any assumption does not hold, do not expose ArcherDB directly. Introduce an external security boundary (gateway/proxy/service mesh) and infrastructure encryption controls before expanding trust boundaries.

## When to Add External Controls

Add or strengthen external controls when:

- Remote access is required (non-local clients)
- Multi-tenant isolation is required
- Compliance controls require auditable authn/authz and encrypted transport
- Data sensitivity requires defense in depth
- Any workload introduces untrusted clients or networks

## Related Documentation

- [Disaster Recovery](./disaster-recovery.md) - External backup and restore procedures
- [Operations Runbook](./operations-runbook.md) - Day-to-day operational procedures
- [Encryption Guide](./encryption-guide.md) - External encryption-at-rest controls
- [Encryption Security](./encryption-security.md) - Data-protection model and non-goals
- [Upgrade Guide](./upgrade-guide.md) - Secure upgrade procedures
