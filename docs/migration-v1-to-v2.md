# Migration Guide: v1 to v2

This guide covers migrating ArcherDB from v1.x to v2.x releases.

## Overview

ArcherDB v2 introduces major features for distributed deployments:

| Feature | v2.0 | v2.1 | v2.2 |
|---------|------|------|------|
| Async log shipping | ✓ | ✓ | ✓ |
| Read-only followers | ✓ | ✓ | ✓ |
| Stop-the-world resharding | ✓ | ✓ | ✓ |
| Encryption at rest | ✓ | ✓ | ✓ |
| Online resharding | | ✓ | ✓ |
| Hot-warm-cold tiering | | ✓ | ✓ |
| TTL extension on read | | ✓ | ✓ |
| Active-active replication | | | ✓ |
| Geo-sharding | | | ✓ |

## Pre-Migration Checklist

Before upgrading:

1. **Backup your cluster**
   ```bash
   archerdb backup create --name pre-v2-migration
   archerdb backup verify --name pre-v2-migration
   ```

2. **Verify cluster health**
   ```bash
   archerdb cluster status
   archerdb metrics | grep replica_lag
   ```

3. **Review breaking changes** (see below)

4. **Plan maintenance window** (v1→v2.0 requires brief downtime)

5. **Update client SDKs** to v2-compatible versions

## Breaking Changes

### Wire Protocol v2

The wire protocol includes new fields for multi-region routing:

- `region_id` field added to message headers
- `shard_id` field added for sharded clusters
- **Impact**: Clients must be upgraded before or simultaneously with servers

### Data File Format v2

Encrypted clusters use a new file format:

- 96-byte encryption header prepended to data files
- **Impact**: Cannot downgrade to v1 after enabling encryption

### Configuration Changes

New required configuration for distributed features:

```bash
# v1 configuration
--addresses=node1:3000,node2:3000,node3:3000

# v2 configuration (adds region and shard options)
--addresses=node1:3000,node2:3000,node3:3000
--region-id=us-west-2
--shard-count=1
```

### Error Codes

New error code ranges added:

| Range | Category |
|-------|----------|
| 213-218 | Multi-region errors |
| 220-224 | Sharding errors |
| 230-233 | Tiering errors |
| 240-243 | TTL extension errors |
| 410-414 | Encryption errors |

Client applications should handle these new error codes.

## Migration Steps

### Step 1: Upgrade Client SDKs

Update all client applications to v2-compatible SDK versions:

| SDK | v1 Version | v2 Version |
|-----|------------|------------|
| Go | v1.x | v2.0.0+ |
| Python | v1.x | v2.0.0+ |
| Node.js | v1.x | v2.0.0+ |
| Java | v1.x | v2.0.0+ |
| Rust | v1.x | v2.0.0+ |
| .NET | v1.x | v2.0.0+ |
| C | v1.x | v2.0.0+ |

v2 SDKs are backward-compatible with v1 servers.

### Step 2: Upgrade Server Binaries

For each node in the cluster:

```bash
# 1. Stop the node gracefully
systemctl stop archerdb

# 2. Install v2 binary
wget https://releases.archerdb.io/v2.0.0/archerdb-linux-amd64
chmod +x archerdb-linux-amd64
mv archerdb-linux-amd64 /usr/local/bin/archerdb

# 3. Start with v2 configuration
systemctl start archerdb

# 4. Verify node joined cluster
archerdb cluster status
```

**Important**: Upgrade one node at a time, waiting for it to sync before proceeding.

### Step 3: Verify Upgrade

After all nodes are upgraded:

```bash
# Check cluster version
archerdb version --cluster

# Verify all replicas healthy
archerdb cluster status

# Run test queries
archerdb query radius --lat 37.7749 --lon -122.4194 --radius 1000
```

## Enabling v2 Features

### Multi-Region Replication (v2.0)

To add a follower region:

```bash
# On primary region
archerdb region add --name us-east-1 --endpoint follower.us-east-1.example.com:3000

# On follower region (new deployment)
archerdb start \
  --role=follower \
  --primary-region=primary.us-west-2.example.com:3000 \
  --region-id=us-east-1
```

### Encryption at Rest (v2.0)

Enable encryption for new clusters:

```bash
archerdb start \
  --encryption-enabled=true \
  --encryption-key-provider=aws-kms \
  --encryption-key-id=alias/archerdb-master-key
```

**Note**: Enabling encryption on existing clusters requires data migration.

### Resharding (v2.0/v2.1)

Expand from 1 to 4 shards:

```bash
# v2.0: Stop-the-world resharding (requires downtime)
archerdb shard reshard --to 4 --mode=offline

# v2.1: Online resharding (minimal downtime)
archerdb shard reshard --to 4 --mode=online
```

### Data Tiering (v2.1)

Enable hot-warm-cold tiering:

```bash
archerdb start \
  --tiering-enabled=true \
  --tiering-hot-threshold=7d \
  --tiering-warm-threshold=30d \
  --tiering-cold-storage=s3://my-bucket/archerdb-cold
```

### TTL Extension on Read (v2.1)

Enable automatic TTL extension:

```bash
archerdb start \
  --ttl-extension-enabled=true \
  --ttl-extension-amount=86400 \
  --ttl-extension-max=2592000 \
  --ttl-extension-cooldown=3600
```

## SDK Migration Examples

### Go SDK

```go
// v1: Simple connection
client, _ := archerdb.NewClient(archerdb.Config{
    Addresses: []string{"node1:3000"},
})

// v2: Region-aware connection
client, _ := archerdb.NewClient(archerdb.Config{
    Addresses:      []string{"node1:3000"},
    PreferRegion:   "us-west-2",
    FollowerReads:  true,  // Enable reads from followers
})
```

### Python SDK

```python
# v1: Simple connection
client = GeoClient(cluster_id=0, addresses=["node1:3000"])

# v2: Region-aware connection
client = GeoClient(
    cluster_id=0,
    addresses=["node1:3000"],
    prefer_region="us-west-2",
    follower_reads=True,
)
```

### TTL Operations (v2.1)

All SDKs now support TTL operations:

```python
# Set TTL
response = client.set_ttl(entity_id, ttl_seconds=86400)

# Extend TTL
response = client.extend_ttl(entity_id, extend_by_seconds=3600)

# Clear TTL (entity never expires)
response = client.clear_ttl(entity_id)
```

## Rollback Procedure

If issues occur during migration:

1. **Stop upgraded nodes**
   ```bash
   systemctl stop archerdb
   ```

2. **Restore v1 binary**
   ```bash
   mv /usr/local/bin/archerdb.v1-backup /usr/local/bin/archerdb
   ```

3. **Restore from backup** (if data corruption occurred)
   ```bash
   archerdb restore --backup pre-v2-migration
   ```

4. **Restart with v1 configuration**
   ```bash
   systemctl start archerdb
   ```

**Important**: Rollback is NOT possible after enabling encryption.

## Troubleshooting

### "Version mismatch" errors

Ensure all nodes are running the same version:
```bash
archerdb version --cluster
```

### "Unknown error code" in client

Update client SDK to v2 version that understands new error codes.

### Replication lag after upgrade

Monitor lag metrics:
```bash
archerdb metrics | grep replication_lag
```

High lag is normal during initial sync. Wait for convergence.

### Encryption key unavailable

Check KMS/Vault connectivity:
```bash
archerdb verify --encryption
```

## Support

For migration assistance:
- Documentation: https://docs.archerdb.io/migration
- GitHub Issues: https://github.com/archerdb/archerdb/issues
- Community Discord: https://discord.gg/archerdb
