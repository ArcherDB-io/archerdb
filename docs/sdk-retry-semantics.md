# SDK Retry Semantics

This document describes the retry behavior of ArcherDB client SDKs, including multi-batch retry patterns, idempotency guarantees, and configuration options.

## Overview

ArcherDB SDKs implement automatic retry with exponential backoff for transient failures. Retries are enabled by default and preserve idempotency guarantees, making it safe to retry operations without risk of duplicate execution.

## Retry Configuration

All SDKs support the following configuration parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `enabled` | `true` | Enable/disable automatic retry |
| `max_retries` | `5` | Maximum retry attempts after initial failure |
| `base_backoff_ms` | `100` | Base delay for exponential backoff |
| `max_backoff_ms` | `1600` | Maximum backoff delay cap |
| `total_timeout_ms` | `30000` | Total timeout across all attempts |
| `jitter` | `true` | Add random jitter to prevent thundering herd |

### Node.js

```typescript
import { createGeoClient, RetryConfig } from 'archerdb-node'

const client = createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3000'],
  retry: {
    enabled: true,
    max_retries: 5,
    base_backoff_ms: 100,
    max_backoff_ms: 1600,
    total_timeout_ms: 30000,
    jitter: true,
  }
})
```

### Python

```python
import archerdb

client = archerdb.GeoClientSync(archerdb.GeoClientConfig(
    cluster_id=0,
    addresses=['127.0.0.1:3000'],
    retry=archerdb.RetryConfig(
        enabled=True,
        max_retries=5,
        base_backoff_ms=100,
        max_backoff_ms=1600,
        total_timeout_ms=30000,
        jitter=True,
    )
))
```

### Go

```go
import (
    "github.com/tigerbeetle/tigerbeetle-go/pkg/retry"
)

config := retry.DefaultConfig()
config.MaxRetries = 5
config.BaseBackoffMs = 100
config.MaxBackoffMs = 1600
config.TotalTimeoutMs = 30000
config.Jitter = true
```

## Backoff Schedule

The SDK uses exponential backoff with the following schedule:

| Attempt | Base Delay | With Jitter (typical) |
|---------|------------|----------------------|
| 1 | 0ms | 0ms (immediate) |
| 2 | 100ms | 100-150ms |
| 3 | 200ms | 200-300ms |
| 4 | 400ms | 400-600ms |
| 5 | 800ms | 800-1200ms |
| 6 | 1600ms | 1600-2400ms |

**Jitter Formula:** `actual_delay = base_delay + random(0, base_delay / 2)`

Jitter prevents the "thundering herd" problem where many clients retry simultaneously after a transient failure.

## Error Classification

### Retryable Errors (Transient)

These errors are automatically retried:

- `timeout` - Operation timed out
- `view_change_in_progress` - Leader election in progress
- `not_primary` - Connected to non-primary replica
- `cluster_unavailable` - No quorum available
- `session_expired` - Session needs re-registration
- Network errors (connection reset, refused, timeout)

### Non-Retryable Errors (Permanent)

These errors fail immediately without retry:

- `invalid_coordinates` - Coordinates out of valid range
- `polygon_too_complex` - Too many vertices
- `batch_too_large` - Batch exceeds maximum size
- `query_result_too_large` - Query limit exceeded
- `invalid_entity_id` - Zero or malformed entity ID
- TLS/certificate errors

## Multi-Batch Retry Pattern

When a large batch operation times out, the SDK cannot determine which events succeeded vs. failed. The `split_batch` helper enables safe retry by dividing the batch into smaller chunks.

### The Problem

```
[Event 0] [Event 1] [Event 2] ... [Event 9999]
                         ^
                         | Timeout occurs here
                         | Events 0-2000 committed
                         | Events 2001-9999 unknown
```

After a timeout, you don't know which events committed. Simply retrying the entire batch risks duplicate processing (though server-side idempotency may prevent this for some operations).

### The Solution: split_batch

Split the batch into smaller chunks and retry each chunk individually:

```
Original:  [0..9999] → TIMEOUT

Split:     [0..999] → SUCCESS (or already committed)
           [1000..1999] → SUCCESS
           [2000..2999] → SUCCESS
           ...
```

### Node.js

```typescript
import { splitBatch, OperationTimeout } from 'archerdb-node'

const events = generateLargeEventList()

try {
  const batch = client.createBatch()
  for (const event of events) {
    batch.add(event)
  }
  await batch.commit()
} catch (error) {
  if (error instanceof OperationTimeout) {
    // Split into smaller chunks and retry
    const chunks = splitBatch(events, 500)

    for (const chunk of chunks) {
      const retryBatch = client.createBatch()
      for (const event of chunk) {
        retryBatch.add(event)
      }
      try {
        await retryBatch.commit()
      } catch (retryError) {
        if (retryError instanceof OperationTimeout) {
          // Retry with even smaller chunks
          const smallerChunks = splitBatch(chunk, 100)
          // ... continue recursively
        }
      }
    }
  }
}
```

### Python

```python
from archerdb import split_batch, OperationTimeout

events = generate_large_event_list()

try:
    batch = client.create_batch()
    for event in events:
        batch.add(event)
    batch.commit()
except OperationTimeout:
    # Split into smaller chunks and retry
    chunks = split_batch(events, 500)

    for chunk in chunks:
        retry_batch = client.create_batch()
        for event in chunk:
            retry_batch.add(event)
        try:
            retry_batch.commit()
        except OperationTimeout:
            # Retry with even smaller chunks
            smaller_chunks = split_batch(chunk, 100)
            # ... continue recursively
```

### Go

```go
import "github.com/tigerbeetle/tigerbeetle-go/pkg/types"

accounts := generateLargeAccountList()

// Original batch failed - split and retry
chunks := types.SplitAccountBatch(accounts, 500)

for _, chunk := range chunks {
    _, err := client.CreateAccounts(chunk)
    if errors.Is(err, errors.ErrTimeout) {
        // Retry with smaller chunks
        smallerChunks := types.SplitAccountBatch(chunk, 100)
        // ... continue recursively
    }
}
```

## Idempotency Guarantees

### Server-Side Deduplication

The server maintains client sessions and deduplicates requests based on `client_id` + `request_number`. When retrying:

1. SDK uses the **same** `request_number` for all retry attempts
2. If the request already executed, server returns the cached response
3. No double-execution occurs for idempotent operations

### Idempotent vs Non-Idempotent Operations

| Operation | Idempotent | Safe to Retry |
|-----------|------------|---------------|
| `upsert_events` | Yes | Yes |
| `query_*` | Yes | Yes |
| `delete_entities` | Yes | Yes |
| `insert_events` | **No** | Use with caution |

**Recommendation:** Prefer `upsert_events` over `insert_events` for safer retry behavior.

### Session Recovery

If the client crashes between sending a request and receiving a response:

- New client instance generates a new `client_id`
- Cannot rely on deduplication from the old session
- Application may need to handle potential duplicates

## Retry Exhaustion

When all retry attempts are exhausted, the SDK returns a `RetryExhausted` error with:

- Number of attempts made
- The last error from the final attempt

### Node.js

```typescript
import { RetryExhausted } from 'archerdb-node'

try {
  await batch.commit()
} catch (error) {
  if (error instanceof RetryExhausted) {
    console.log(`Failed after ${error.attempts} attempts`)
    console.log(`Last error: ${error.lastError.message}`)
  }
}
```

### Python

```python
from archerdb import RetryExhausted

try:
    batch.commit()
except RetryExhausted as e:
    print(f"Failed after {e.attempts} attempts")
    print(f"Last error: {e.last_error}")
```

### Go

```go
import "github.com/tigerbeetle/tigerbeetle-go/pkg/retry"

err := retry.Do(func() error {
    _, err := client.CreateAccounts(accounts)
    return err
}, config)

var exhausted retry.ErrRetryExhausted
if errors.As(err, &exhausted) {
    fmt.Printf("Failed after %d attempts\n", exhausted.Attempts)
    fmt.Printf("Last error: %v\n", exhausted.LastError)
}
```

## Best Practices

1. **Use upsert over insert** - Upsert operations are idempotent and safe to retry.

2. **Keep batches reasonably sized** - Smaller batches (500-1000 events) have better retry characteristics than maximum-sized batches.

3. **Handle RetryExhausted** - Always catch retry exhaustion and implement application-level fallback.

4. **Use split_batch for large imports** - When importing large datasets, proactively split into chunks rather than waiting for timeouts.

5. **Monitor retry metrics** - Track retry counts in production to detect cluster issues early.

6. **Don't disable retry without reason** - The default retry configuration handles most transient failures automatically.

## Related Documentation

- [Client SDK Specification](../openspec/changes/add-geospatial-core/specs/client-sdk/spec.md)
- [Client Retry Specification](../openspec/changes/add-geospatial-core/specs/client-retry/spec.md)
- [Error Codes Reference](../openspec/changes/add-geospatial-core/specs/error-codes/spec.md)
