# ArcherDB Error Codes Reference

This document provides a complete reference for all ArcherDB error codes, including v2 distributed features.

## Error Code Ranges

| Range | Category | Description |
|-------|----------|-------------|
| 0 | Success | Operation succeeded |
| 1-99 | Protocol | Message format, checksums, version |
| 100-199 | Validation | Invalid inputs, constraint violations |
| 200-299 | State | Entity/cluster state errors |
| 300-399 | Resource | Limits exceeded, capacity constraints |
| 400-499 | Security | Authentication, authorization |
| 500-599 | Internal | Bugs (should not occur in production) |

## Retry Semantics

Errors are classified into three categories:

- **Retryable**: Transient errors that may succeed on retry (e.g., leader election, network issues)
- **Client Error**: Invalid request that will always fail (fix the request, don't retry)
- **Fatal**: Server-side bugs (contact support)

## v2 Error Codes

### Multi-Region Errors (213-218)

These errors occur in multi-region deployments with async replication.

| Code | Name | Message | Retryable |
|------|------|---------|-----------|
| 213 | `FOLLOWER_READ_ONLY` | Write operation rejected: follower regions are read-only | No |
| 214 | `STALE_FOLLOWER` | Follower data exceeds maximum staleness threshold | Yes |
| 215 | `PRIMARY_UNREACHABLE` | Cannot connect to primary region | Yes |
| 216 | `REPLICATION_TIMEOUT` | Cross-region replication timeout | Yes |
| 217 | `REGION_CONFIG_MISMATCH` | Region configuration does not match cluster topology | No |
| 218 | `UNKNOWN_REGION` | Unknown region specified in request | No |

**Usage Notes:**
- Code 213: Writes must go to the primary region. SDKs automatically route writes to primary.
- Code 214: The follower hasn't caught up with replication. Wait and retry, or use a fresher replica.
- Code 215: The primary region is down. Wait for failover or recovery.
- Code 216: Cross-region replication is slow. Retry with backoff.

### Sharding Errors (220-224)

These errors occur in sharded cluster deployments.

| Code | Name | Message | Retryable |
|------|------|---------|-----------|
| 220 | `NOT_SHARD_LEADER` | This node is not the leader for target shard | Yes |
| 221 | `SHARD_UNAVAILABLE` | Target shard has no available replicas | Yes |
| 222 | `RESHARDING_IN_PROGRESS` | Cluster is currently resharding | Yes |
| 223 | `INVALID_SHARD_COUNT` | Target shard count is invalid | No |
| 224 | `SHARD_MIGRATION_FAILED` | Data migration to new shard failed | No |

**Usage Notes:**
- Code 220: SDKs automatically refresh topology and retry. No application action needed.
- Code 221: Wait for shard recovery. The cluster may be experiencing failures.
- Code 222: Wait for resharding to complete. Operations will succeed after.
- Code 223: The requested shard count is not valid (e.g., must be power of 2).
- Code 224: A resharding operation failed. Check cluster health.

### Encryption Errors (410-414)

These errors occur with encryption at rest enabled.

| Code | Name | Message | Retryable |
|------|------|---------|-----------|
| 410 | `ENCRYPTION_KEY_UNAVAILABLE` | Cannot retrieve encryption key from provider | Yes |
| 411 | `DECRYPTION_FAILED` | Failed to decrypt data (auth tag mismatch) | No |
| 412 | `ENCRYPTION_NOT_ENABLED` | Encryption required but not configured | No |
| 413 | `KEY_ROTATION_IN_PROGRESS` | Key rotation in progress, retry later | Yes |
| 414 | `UNSUPPORTED_ENCRYPTION_VERSION` | File encrypted with unsupported version | No |

**Usage Notes:**
- Code 410: KMS/Vault connectivity issue. Check key provider health.
- Code 411: Data corruption or tampering detected. Data integrity compromised.
- Code 412: Server requires encryption but client didn't configure it.
- Code 413: Wait for key rotation to complete. Operations will succeed after.
- Code 414: Upgrade server to support the encryption version.

## SDK Error Handling

### Python

```python
from archerdb import (
    MultiRegionError,
    ShardingError,
    EncryptionError,
    MultiRegionException,
    ShardingException,
    EncryptionException,
    is_retryable,
)

try:
    result = client.query_radius(lat, lon, radius)
except ShardingException as e:
    if e.error == ShardingError.RESHARDING_IN_PROGRESS:
        # Wait and retry - cluster is resharding
        time.sleep(5)
        result = client.query_radius(lat, lon, radius)
    elif is_retryable(e.code):
        # Generic retry logic
        result = retry_with_backoff(lambda: client.query_radius(lat, lon, radius))
    else:
        raise  # Non-retryable error
```

### Java

```java
import com.archerdb.geo.ShardingError;
import com.archerdb.geo.EncryptionError;
import com.archerdb.geo.ArcherDBException;

try {
    QueryResult result = client.queryRadius(lat, lon, radius);
} catch (ArcherDBException e) {
    ShardingError shardError = ShardingError.fromCode(e.getErrorCode());
    if (shardError != null && shardError.isRetryable()) {
        // Retry with backoff
    }
    EncryptionError encError = EncryptionError.fromCode(e.getErrorCode());
    if (encError != null && encError.isRetryable()) {
        // Retry with backoff
    }
}
```

### Go

```go
import "github.com/archerdb/archerdb-go/pkg/errors"

result, err := client.QueryRadius(lat, lon, radius)
if err != nil {
    if archerErr, ok := err.(*errors.ArcherDBError); ok {
        if errors.IsShardingError(int(archerErr.Code)) {
            if errors.IsRetryable(int(archerErr.Code)) {
                // Retry with backoff
            }
        }
    }
}
```

### Node.js/TypeScript

```typescript
import {
    ShardingError,
    ShardingException,
    isShardingError,
    isRetryable,
} from 'archerdb';

try {
    const result = await client.queryRadius(lat, lon, radius);
} catch (e) {
    if (e instanceof ShardingException) {
        if (e.error === ShardingError.RESHARDING_IN_PROGRESS) {
            // Wait and retry
            await sleep(5000);
            result = await client.queryRadius(lat, lon, radius);
        }
    }
}
```

## Troubleshooting Guide

### Multi-Region Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| All writes fail with 213 | Connected to follower | Configure SDK with primary region |
| Reads return stale data | Replication lag | Check `read_staleness_ns` header |
| 215 errors during failover | Primary down | Wait for new primary election |

### Sharding Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Frequent 220 errors | Topology cache stale | Reduce `topology_refresh_interval` |
| 221 errors cluster-wide | Shard failure | Check cluster health, may need recovery |
| Long 222 wait times | Large resharding | Monitor resharding progress |

### Encryption Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| 410 errors at startup | KMS connectivity | Check KMS credentials and network |
| 411 errors on read | Data corruption | Restore from backup |
| 413 during rotation | Key rotation | Wait for completion (~minutes) |

## Related Documentation

- [SDK Retry Semantics](sdk-retry-semantics.md) - Detailed retry configuration
- [Disaster Recovery](disaster-recovery.md) - Recovery procedures
- [Operations Runbook](operations-runbook.md) - Operational procedures
