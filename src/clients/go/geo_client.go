// Package archerdb provides a high-performance Go client for ArcherDB, a geospatial database
// optimized for real-time location tracking and spatial queries.
//
// ArcherDB is designed for applications that need to track millions of moving entities
// (vehicles, devices, people) with sub-millisecond query latency. The Go SDK provides
// a thread-safe client that can be shared across goroutines.
//
// # Quick Start
//
// Create a client and insert a geo event:
//
//	client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
//	    ClusterID: types.ToUint128(0),
//	    Addresses: []string{"127.0.0.1:3001"},
//	})
//	if err != nil {
//	    log.Fatal(err)
//	}
//	defer client.Close()
//
//	event, _ := types.NewGeoEvent(types.GeoEventOptions{
//	    EntityID:  types.ID(),
//	    Latitude:  37.7749,
//	    Longitude: -122.4194,
//	})
//	errors, err := client.InsertEvents([]types.GeoEvent{event})
//
// # Thread Safety
//
// The GeoClient is safe for concurrent use by multiple goroutines. A single client
// instance should be created and shared across your application. The client manages
// connection pooling and request multiplexing internally.
//
// # Error Handling
//
// All errors implement the GeoError interface and support errors.Is for type checking:
//
//	if errors.Is(err, archerdb.ErrConnectionFailed) {
//	    // Handle connection failure
//	}
//
// See the errors package for category helpers like IsNetworkError and IsValidationError.
//
// # Context Support
//
// Operations support Go context for cancellation and timeouts through the standard
// client interface. Set request timeouts via GeoClientConfig.RequestTimeout.
package archerdb

/*
#cgo CFLAGS: -g -Wall
#cgo darwin,arm64 LDFLAGS: ${SRCDIR}/pkg/native/libarch_client_aarch64-macos.a -ldl -lm
#cgo darwin,amd64 LDFLAGS: ${SRCDIR}/pkg/native/libarch_client_x86_64-macos.a -ldl -lm
#cgo linux,arm64 LDFLAGS: ${SRCDIR}/pkg/native/libarch_client_aarch64-linux.a -ldl -lm
#cgo linux,amd64 LDFLAGS: ${SRCDIR}/pkg/native/libarch_client_x86_64-linux.a -ldl -lm
#cgo windows,amd64 LDFLAGS: -L${SRCDIR}/pkg/native -larch_client_x86_64-windows -lws2_32 -lntdll

#include <stdlib.h>
#include <string.h>
#include "./pkg/native/arch_client.h"

#ifndef __declspec
	#define __declspec(x)
#endif

typedef const uint8_t* arch_result_bytes_t;

extern __declspec(dllexport) void onGoPacketCompletion(
	uintptr_t ctx,
	arch_packet_t* packet,
	uint64_t timestamp,
	arch_result_bytes_t result_ptr,
	uint32_t result_len
);
*/
import "C"
import (
	"encoding/binary"
	stderrors "errors"
	"fmt"
	"math/rand"
	"runtime"
	"strings"
	"time"
	"unsafe"

	"github.com/archerdb/archerdb-go/pkg/errors"
	"github.com/archerdb/archerdb-go/pkg/observability"
	"github.com/archerdb/archerdb-go/pkg/types"
)

// ============================================================================
// Error Types (per SDK spec)
// ============================================================================

// GeoError is the base interface for all ArcherDB errors.
//
// All error types returned by ArcherDB operations implement this interface,
// providing access to error codes and retry eligibility. Use errors.Is for
// type checking and the Code() method for programmatic error handling.
//
// Example:
//
//	result, err := client.QueryRadius(filter)
//	if err != nil {
//	    if geoErr, ok := err.(archerdb.GeoError); ok {
//	        log.Printf("Error code %d, retryable: %v", geoErr.Code(), geoErr.Retryable())
//	    }
//	}
type GeoError interface {
	error
	// Code returns the numeric error code for programmatic handling.
	// See error-codes.md for the complete list of error codes.
	Code() int
	// Retryable returns true if the operation can be safely retried.
	// Network errors are typically retryable; validation errors are not.
	Retryable() bool
}

// Sentinel error variables for errors.Is comparisons.
// Use these with errors.Is() for type-safe error checking:
//
//	if errors.Is(err, archerdb.ErrConnectionFailed) {
//	    // Handle connection failure
//	}
var (
	// ErrConnectionFailed is returned when the client cannot connect to any cluster node.
	ErrConnectionFailed = &ConnectionFailedError{}
	// ErrConnectionTimeout is returned when a connection attempt times out.
	ErrConnectionTimeout = &ConnectionTimeoutError{}
	// ErrClusterUnavailable is returned when the cluster is unavailable after retries.
	ErrClusterUnavailable = &ClusterUnavailableError{}
	// ErrInvalidCoordinates is returned when coordinates are outside valid ranges.
	ErrInvalidCoordinates = &InvalidCoordinatesError{}
	// ErrBatchTooLarge is returned when a batch exceeds the maximum size (10,000 events).
	ErrBatchTooLarge = &BatchTooLargeError{}
	// ErrInvalidEntityID is returned when an entity ID is invalid (e.g., zero).
	ErrInvalidEntityID = &InvalidEntityIDError{}
	// ErrEntityExpired is returned when querying an entity that has expired due to TTL.
	ErrEntityExpired = &EntityExpiredError{}
	// ErrOperationTimeout is returned when an operation times out.
	ErrOperationTimeout = &OperationTimeoutError{}
	// ErrQueryResultTooLarge is returned when query limit exceeds maximum (81,000).
	ErrQueryResultTooLarge = &QueryResultTooLargeError{}
	// ErrClientClosed is returned when operations are attempted on a closed client.
	ErrClientClosed = &ClientClosedError{}
	// ErrRetryExhausted is returned when all retry attempts have been exhausted.
	ErrRetryExhausted = &RetryExhaustedError{}
)

// ConnectionFailedError indicates failure to establish connection to any cluster node.
// This is a retryable error - the client will attempt to reconnect automatically
// if retry is enabled.
//
// Error code: 1001
type ConnectionFailedError struct{ Msg string }

func (e ConnectionFailedError) Error() string   { return e.Msg }
func (e ConnectionFailedError) Code() int       { return 1001 }
func (e ConnectionFailedError) Retryable() bool { return true }

// Is implements errors.Is support for ConnectionFailedError.
func (e *ConnectionFailedError) Is(target error) bool {
	_, ok := target.(*ConnectionFailedError)
	return ok
}

// ConnectionTimeoutError indicates a connection attempt exceeded the configured timeout.
// This is a retryable error - the client may succeed on retry if network issues resolve.
//
// Error code: 1002
type ConnectionTimeoutError struct{ Msg string }

func (e ConnectionTimeoutError) Error() string   { return e.Msg }
func (e ConnectionTimeoutError) Code() int       { return 1002 }
func (e ConnectionTimeoutError) Retryable() bool { return true }

// Is implements errors.Is support for ConnectionTimeoutError.
func (e *ConnectionTimeoutError) Is(target error) bool {
	_, ok := target.(*ConnectionTimeoutError)
	return ok
}

// ClusterUnavailableError indicates the cluster is not accepting requests.
// This typically occurs during leader election or when a quorum is unavailable.
// This is a retryable error - retry after a brief delay.
//
// Error code: 2001
type ClusterUnavailableError struct{ Msg string }

func (e ClusterUnavailableError) Error() string   { return e.Msg }
func (e ClusterUnavailableError) Code() int       { return 2001 }
func (e ClusterUnavailableError) Retryable() bool { return true }

// Is implements errors.Is support for ClusterUnavailableError.
func (e *ClusterUnavailableError) Is(target error) bool {
	_, ok := target.(*ClusterUnavailableError)
	return ok
}

// InvalidCoordinatesError indicates coordinates are outside valid ranges.
// Latitude must be in [-90, +90] degrees; longitude must be in [-180, +180] degrees.
// This is NOT a retryable error - fix the input coordinates.
//
// Error code: 3001
type InvalidCoordinatesError struct{ Msg string }

func (e InvalidCoordinatesError) Error() string   { return e.Msg }
func (e InvalidCoordinatesError) Code() int       { return 3001 }
func (e InvalidCoordinatesError) Retryable() bool { return false }

// Is implements errors.Is support for InvalidCoordinatesError.
func (e *InvalidCoordinatesError) Is(target error) bool {
	_, ok := target.(*InvalidCoordinatesError)
	return ok
}

// BatchTooLargeError indicates a batch exceeds the maximum size.
// The maximum batch size is 10,000 events. Split larger batches into smaller chunks.
// This is NOT a retryable error - reduce the batch size.
//
// Error code: 3003
type BatchTooLargeError struct{ Msg string }

func (e BatchTooLargeError) Error() string   { return e.Msg }
func (e BatchTooLargeError) Code() int       { return 3003 }
func (e BatchTooLargeError) Retryable() bool { return false }

// Is implements errors.Is support for BatchTooLargeError.
func (e *BatchTooLargeError) Is(target error) bool {
	_, ok := target.(*BatchTooLargeError)
	return ok
}

// InvalidEntityIDError indicates an entity ID is invalid.
// Entity IDs must not be zero. Use types.ID() to generate valid UUIDs.
// This is NOT a retryable error - provide a valid entity ID.
//
// Error code: 3004
type InvalidEntityIDError struct{ Msg string }

func (e InvalidEntityIDError) Error() string   { return e.Msg }
func (e InvalidEntityIDError) Code() int       { return 3004 }
func (e InvalidEntityIDError) Retryable() bool { return false }

// Is implements errors.Is support for InvalidEntityIDError.
func (e *InvalidEntityIDError) Is(target error) bool {
	_, ok := target.(*InvalidEntityIDError)
	return ok
}

// EntityExpiredError indicates an entity has expired due to TTL.
// The entity existed but its TTL has elapsed. This is expected behavior for
// time-limited data. This is NOT a retryable error.
//
// Error code: 210
type EntityExpiredError struct{ Msg string }

func (e EntityExpiredError) Error() string   { return e.Msg }
func (e EntityExpiredError) Code() int       { return 210 }
func (e EntityExpiredError) Retryable() bool { return false }

// Is implements errors.Is support for EntityExpiredError.
func (e *EntityExpiredError) Is(target error) bool {
	_, ok := target.(*EntityExpiredError)
	return ok
}

// OperationTimeoutError indicates an operation exceeded its configured timeout.
// This is a retryable error - the operation may succeed on retry.
//
// Error code: 4001
type OperationTimeoutError struct{ Msg string }

func (e OperationTimeoutError) Error() string   { return e.Msg }
func (e OperationTimeoutError) Code() int       { return 4001 }
func (e OperationTimeoutError) Retryable() bool { return true }

// Is implements errors.Is support for OperationTimeoutError.
func (e *OperationTimeoutError) Is(target error) bool {
	_, ok := target.(*OperationTimeoutError)
	return ok
}

// QueryResultTooLargeError indicates a query limit exceeds the maximum.
// The maximum query limit is 81,000 results. Use pagination for larger result sets.
// This is NOT a retryable error - reduce the limit.
//
// Error code: 4002
type QueryResultTooLargeError struct{ Msg string }

func (e QueryResultTooLargeError) Error() string   { return e.Msg }
func (e QueryResultTooLargeError) Code() int       { return 4002 }
func (e QueryResultTooLargeError) Retryable() bool { return false }

// Is implements errors.Is support for QueryResultTooLargeError.
func (e *QueryResultTooLargeError) Is(target error) bool {
	_, ok := target.(*QueryResultTooLargeError)
	return ok
}

// ClientClosedError indicates operations were attempted on a closed client.
// Once Close() is called, the client cannot be reused. Create a new client.
// This is NOT a retryable error.
//
// Error code: 5001
type ClientClosedError struct{ Msg string }

func (e ClientClosedError) Error() string   { return e.Msg }
func (e ClientClosedError) Code() int       { return 5001 }
func (e ClientClosedError) Retryable() bool { return false }

// Is implements errors.Is support for ClientClosedError.
func (e *ClientClosedError) Is(target error) bool {
	_, ok := target.(*ClientClosedError)
	return ok
}

// RetryExhaustedError indicates all retry attempts have been exhausted.
// This wraps the last error encountered during retry attempts.
// Check LastError for the underlying cause.
//
// Error code: 5002
type RetryExhaustedError struct {
	// Attempts is the total number of attempts made (including the initial attempt).
	Attempts int
	// LastError is the error from the final attempt.
	LastError error
}

func (e RetryExhaustedError) Error() string {
	return fmt.Sprintf("all %d retry attempts exhausted, last error: %v", e.Attempts, e.LastError)
}
func (e RetryExhaustedError) Code() int       { return 5002 }
func (e RetryExhaustedError) Retryable() bool { return false }

// Unwrap returns the underlying error for errors.Unwrap support.
func (e RetryExhaustedError) Unwrap() error {
	return e.LastError
}

// Is implements errors.Is support for RetryExhaustedError.
func (e *RetryExhaustedError) Is(target error) bool {
	_, ok := target.(*RetryExhaustedError)
	return ok
}

// IsNetworkError returns true if err is any network-related error.
// Network errors are typically retryable and include connection failures,
// timeouts, and cluster unavailability.
//
// Example:
//
//	if archerdb.IsNetworkError(err) {
//	    log.Printf("Network error, will retry: %v", err)
//	}
func IsNetworkError(err error) bool {
	if err == nil {
		return false
	}
	var connFailed *ConnectionFailedError
	var connTimeout *ConnectionTimeoutError
	var clusterUnavail *ClusterUnavailableError
	var opTimeout *OperationTimeoutError
	if stderrors.As(err, &connFailed) ||
		stderrors.As(err, &connTimeout) ||
		stderrors.As(err, &clusterUnavail) ||
		stderrors.As(err, &opTimeout) {
		return true
	}
	return false
}

// IsValidationError returns true if err is any validation error.
// Validation errors indicate invalid input and are NOT retryable.
// Fix the input data before retrying.
//
// Example:
//
//	if archerdb.IsValidationError(err) {
//	    log.Printf("Invalid input: %v", err)
//	}
func IsValidationError(err error) bool {
	if err == nil {
		return false
	}
	var invalidCoords *InvalidCoordinatesError
	var batchTooLarge *BatchTooLargeError
	var invalidEntity *InvalidEntityIDError
	var queryTooLarge *QueryResultTooLargeError
	if stderrors.As(err, &invalidCoords) ||
		stderrors.As(err, &batchTooLarge) ||
		stderrors.As(err, &invalidEntity) ||
		stderrors.As(err, &queryTooLarge) {
		return true
	}
	return false
}

// ============================================================================
// Configuration
// ============================================================================

// RetryConfig configures automatic retry behavior for transient failures.
//
// The retry mechanism uses exponential backoff with optional jitter to prevent
// thundering herd problems when multiple clients retry simultaneously.
//
// Backoff calculation: delay = min(base_backoff * 2^(attempt-1), max_backoff)
// With jitter: delay = delay + random(0, delay/2)
//
// Example:
//
//	config := archerdb.RetryConfig{
//	    Enabled:      true,
//	    MaxRetries:   5,              // Up to 5 retries after initial failure
//	    BaseBackoff:  100 * time.Millisecond,
//	    MaxBackoff:   1600 * time.Millisecond,
//	    TotalTimeout: 30 * time.Second,
//	    Jitter:       true,
//	}
type RetryConfig struct {
	// Enabled controls whether automatic retry is active.
	// When false, operations fail immediately on first error.
	// Default: true
	Enabled bool

	// MaxRetries is the maximum number of retry attempts after the initial failure.
	// Total attempts = 1 (initial) + MaxRetries.
	// Default: 5
	MaxRetries int

	// BaseBackoff is the initial backoff delay before the first retry.
	// Subsequent retries double this delay up to MaxBackoff.
	// Default: 100ms
	BaseBackoff time.Duration

	// MaxBackoff is the maximum delay between retry attempts.
	// Backoff will not exceed this value regardless of attempt count.
	// Default: 1600ms
	MaxBackoff time.Duration

	// TotalTimeout is the maximum total time for all retry attempts.
	// If this timeout is reached, RetryExhaustedError is returned.
	// Default: 30s
	TotalTimeout time.Duration

	// Jitter adds randomness to backoff delays to prevent thundering herd.
	// When enabled, adds random(0, delay/2) to each backoff delay.
	// Default: true
	Jitter bool
}

// DefaultRetryConfig returns the default retry configuration.
//
// Default values:
//   - Enabled: true
//   - MaxRetries: 5
//   - BaseBackoff: 100ms
//   - MaxBackoff: 1600ms
//   - TotalTimeout: 30s
//   - Jitter: true
//
// The default backoff sequence (without jitter): 100ms, 200ms, 400ms, 800ms, 1600ms
func DefaultRetryConfig() RetryConfig {
	return RetryConfig{
		Enabled:      true,
		MaxRetries:   5,
		BaseBackoff:  100 * time.Millisecond,
		MaxBackoff:   1600 * time.Millisecond,
		TotalTimeout: 30 * time.Second,
		Jitter:       true,
	}
}

// GeoClientConfig contains configuration options for creating a GeoClient.
//
// Required fields:
//   - Addresses: At least one cluster node address
//
// Optional fields have sensible defaults.
//
// Example:
//
//	config := archerdb.GeoClientConfig{
//	    ClusterID:      types.ToUint128(0),
//	    Addresses:      []string{"127.0.0.1:3001", "127.0.0.1:3002"},
//	    ConnectTimeout: 5 * time.Second,
//	    RequestTimeout: 10 * time.Second,
//	    Retry: &archerdb.RetryConfig{
//	        Enabled:    true,
//	        MaxRetries: 3,
//	    },
//	}
type GeoClientConfig struct {
	// ClusterID is the unique identifier for the ArcherDB cluster.
	// Use types.ToUint128(0) for single-cluster deployments.
	ClusterID types.Uint128

	// Addresses is the list of cluster node addresses (host:port).
	// At least one address is required. The client will connect to any
	// available node and discover the full cluster topology.
	Addresses []string

	// ConnectTimeout is the maximum time to wait for initial connection.
	// Default: 5 seconds
	ConnectTimeout time.Duration

	// RequestTimeout is the maximum time to wait for a single request.
	// This timeout applies to each attempt, not total retry time.
	// Default: 10 seconds
	RequestTimeout time.Duration

	// Retry configures automatic retry behavior for transient failures.
	// If nil, DefaultRetryConfig() is used.
	Retry *RetryConfig
}

// ============================================================================
// GeoClient Interface
// ============================================================================

// GeoClient is the main interface for interacting with an ArcherDB cluster.
//
// GeoClient is safe for concurrent use by multiple goroutines. A single instance
// should be created and shared across your application. The client manages connection
// pooling, request multiplexing, and automatic retry internally.
//
// # Lifecycle
//
// Create a client using NewGeoClient, use it for operations, and call Close when done:
//
//	client, err := archerdb.NewGeoClient(config)
//	if err != nil {
//	    log.Fatal(err)
//	}
//	defer client.Close()
//
// # Operations
//
// The client supports these operation categories:
//
// Insert/Update:
//   - InsertEvents: Insert new geo events
//   - UpsertEvents: Insert or update geo events
//   - DeleteEntities: Delete entities (GDPR-compliant)
//
// Query:
//   - GetLatestByUUID: Get latest event for a single entity
//   - QueryUUIDBatch: Get latest events for multiple entities
//   - QueryRadius: Find events within a circular area
//   - QueryPolygon: Find events within a polygon
//   - QueryLatest: Get most recent events
//
// TTL Management:
//   - SetTTL: Set absolute TTL for an entity
//   - ExtendTTL: Extend existing TTL
//   - ClearTTL: Remove TTL (make permanent)
//
// Cluster:
//   - Ping: Check connectivity
//   - GetStatus: Get server status
//   - GetTopology: Get cluster topology
type GeoClient interface {
	// InsertEvents inserts geo events into the database.
	//
	// Events are inserted atomically - either all succeed or all fail.
	// The returned slice contains errors for events that failed validation.
	// A nil error with empty slice indicates all events were inserted successfully.
	//
	// Maximum batch size is 10,000 events. Use SplitBatch for larger datasets.
	//
	// Example:
	//
	//	errors, err := client.InsertEvents(events)
	//	if err != nil {
	//	    // Network or system error
	//	}
	//	for _, e := range errors {
	//	    log.Printf("Event %d failed: %v", e.Index, e.Result)
	//	}
	InsertEvents(events []types.GeoEvent) ([]types.InsertGeoEventsError, error)

	// UpsertEvents inserts or updates geo events.
	//
	// If an event with the same ID exists, it is updated. Otherwise, it is inserted.
	// Uses Last-Writer-Wins (LWW) semantics for conflict resolution.
	//
	// Returns errors for events that failed validation.
	UpsertEvents(events []types.GeoEvent) ([]types.InsertGeoEventsError, error)

	// DeleteEntities deletes all events for the specified entities.
	//
	// This is a GDPR-compliant deletion that removes all historical data for each
	// entity. The deletion is permanent and cannot be undone.
	//
	// Returns a DeleteResult with counts of deleted and not-found entities.
	DeleteEntities(entityIDs []types.Uint128) (types.DeleteResult, error)

	// GetLatestByUUID returns the most recent event for an entity.
	//
	// Returns nil (not an error) if the entity does not exist.
	// Returns EntityExpiredError if the entity existed but has expired.
	//
	// Example:
	//
	//	event, err := client.GetLatestByUUID(entityID)
	//	if err != nil {
	//	    if errors.Is(err, archerdb.ErrEntityExpired) {
	//	        log.Printf("Entity has expired")
	//	    }
	//	}
	//	if event != nil {
	//	    log.Printf("Last seen: %v", event.Timestamp)
	//	}
	GetLatestByUUID(entityID types.Uint128) (*types.GeoEvent, error)

	// QueryUUIDBatch looks up the latest events for multiple entities in one request.
	//
	// More efficient than multiple GetLatestByUUID calls for batch lookups.
	// Maximum batch size is 10,000 entity IDs.
	//
	// The result contains found events and indices of not-found entities.
	QueryUUIDBatch(entityIDs []types.Uint128) (types.QueryUUIDBatchResult, error)

	// QueryRadius finds events within a circular area.
	//
	// The filter specifies center coordinates (nanodegrees), radius (millimeters),
	// and optional time/group filters. Results are ordered by timestamp (newest first).
	//
	// Use HasMore and Cursor for pagination through large result sets.
	//
	// Example:
	//
	//	filter := types.QueryRadiusFilter{
	//	    CenterLatNano: 37774900000,   // 37.7749 degrees
	//	    CenterLonNano: -122419400000, // -122.4194 degrees
	//	    RadiusMM:      1000000,       // 1 kilometer
	//	    Limit:         100,
	//	}
	//	result, err := client.QueryRadius(filter)
	//	for _, event := range result.Events {
	//	    // Process event
	//	}
	QueryRadius(filter types.QueryRadiusFilter) (types.QueryResult, error)

	// QueryPolygon finds events within a polygon boundary.
	//
	// The polygon is defined by vertices in counter-clockwise order.
	// Supports holes (exclusion zones) defined in clockwise order.
	//
	// Maximum vertices: 10,000 for outer boundary, 100 holes maximum.
	QueryPolygon(filter types.QueryPolygonFilter) (types.QueryResult, error)

	// QueryLatest returns the most recent events globally or filtered by group.
	//
	// Useful for dashboards showing current entity positions.
	// Results are ordered by timestamp (newest first).
	QueryLatest(filter types.QueryLatestFilter) (types.QueryResult, error)

	// Ping verifies connectivity to the server.
	//
	// Returns true if the server responded with a valid pong.
	// Use for health checks and connection validation.
	Ping() (bool, error)

	// GetStatus returns current server status and statistics.
	//
	// Includes RAM index utilization, tombstone count, and TTL expiration counts.
	GetStatus() (types.StatusResponse, error)

	// GetTopology fetches the current cluster topology.
	//
	// Returns shard assignments, primary/replica locations, and cluster health.
	// The topology is also cached internally for shard-aware routing.
	GetTopology() (*types.TopologyResponse, error)

	// GetTopologyCache returns the internal topology cache.
	//
	// Use for inspecting cached topology without a network call.
	// The cache is automatically updated on topology changes.
	GetTopologyCache() *types.TopologyCache

	// RefreshTopology forces an immediate topology refresh from the cluster.
	//
	// Call after receiving a "not shard leader" error to update routing.
	RefreshTopology() error

	// GetShardRouter returns a shard router for advanced shard-aware operations.
	//
	// Use for custom routing logic or scatter-gather queries.
	GetShardRouter() *types.ShardRouter

	// SetTTL sets an absolute TTL (time-to-live) for an entity.
	//
	// After ttlSeconds, the entity will be automatically expired and removed.
	// Replaces any existing TTL. Use 0 to clear TTL (equivalent to ClearTTL).
	//
	// Example:
	//
	//	// Expire entity after 24 hours
	//	resp, err := client.SetTTL(entityID, 86400)
	SetTTL(entityID types.Uint128, ttlSeconds uint32) (*types.TtlSetResponse, error)

	// ExtendTTL extends an entity's existing TTL by a relative amount.
	//
	// Adds extendBySeconds to the current TTL. If no TTL exists, sets a new TTL.
	// Useful for "keep alive" patterns where active entities stay fresh.
	//
	// Example:
	//
	//	// Extend TTL by 1 hour
	//	resp, err := client.ExtendTTL(entityID, 3600)
	ExtendTTL(entityID types.Uint128, extendBySeconds uint32) (*types.TtlExtendResponse, error)

	// ClearTTL removes an entity's TTL, making it permanent.
	//
	// After clearing, the entity will never automatically expire.
	// Use for entities that should be retained indefinitely.
	ClearTTL(entityID types.Uint128) (*types.TtlClearResponse, error)

	// Close releases all resources associated with the client.
	//
	// After Close is called, all operations will return ClientClosedError.
	// Close should be called when the client is no longer needed.
	// It is safe to call Close multiple times.
	Close()
}

// ============================================================================
// GeoEvent Batch Builder
// ============================================================================

// GeoEventBatch provides a builder pattern for accumulating events before submission.
//
// Use batching to improve throughput when inserting many events. Events are validated
// on Add and submitted atomically on Commit.
//
// Example:
//
//	batch := client.CreateBatch()
//	for _, data := range locations {
//	    err := batch.AddFromOptions(types.GeoEventOptions{
//	        EntityID:  data.EntityID,
//	        Latitude:  data.Lat,
//	        Longitude: data.Lon,
//	    })
//	    if err != nil {
//	        log.Printf("Invalid event: %v", err)
//	        continue
//	    }
//	    if batch.IsFull() {
//	        errors, err := batch.Commit()
//	        // Handle results
//	    }
//	}
//	// Commit remaining events
//	errors, err := batch.Commit()
type GeoEventBatch struct {
	events    []types.GeoEvent
	client    *geoClient
	operation string // "insert" or "upsert"
}

// Add adds a pre-constructed GeoEvent to the batch.
//
// The event is validated before being added. Returns an error if:
//   - The batch is full (10,000 events)
//   - Coordinates are invalid
//   - Entity ID is zero
//
// Use AddFromOptions for automatic unit conversion from user-friendly values.
func (b *GeoEventBatch) Add(event types.GeoEvent) error {
	if len(b.events) >= types.BatchSizeMax {
		return BatchTooLargeError{Msg: fmt.Sprintf("batch is full (max %d events)", types.BatchSizeMax)}
	}

	if err := validateGeoEvent(event); err != nil {
		return err
	}

	b.events = append(b.events, event)
	return nil
}

// AddFromOptions creates a GeoEvent from user-friendly options and adds it to the batch.
//
// Handles automatic unit conversion:
//   - Latitude/Longitude: degrees to nanodegrees
//   - Altitude/Accuracy: meters to millimeters
//   - Velocity: meters/second to millimeters/second
//   - Heading: degrees (0-360) to centidegrees
//
// Example:
//
//	err := batch.AddFromOptions(types.GeoEventOptions{
//	    EntityID:  types.ID(),
//	    Latitude:  37.7749,
//	    Longitude: -122.4194,
//	    Heading:   90.0,  // East
//	})
func (b *GeoEventBatch) AddFromOptions(opts types.GeoEventOptions) error {
	event, err := types.NewGeoEvent(opts)
	if err != nil {
		return err
	}
	return b.Add(event)
}

// Count returns the number of events currently in the batch.
func (b *GeoEventBatch) Count() int {
	return len(b.events)
}

// IsFull returns true if the batch has reached its maximum capacity (10,000 events).
//
// Check IsFull before adding events to avoid BatchTooLargeError.
// When full, call Commit to send the batch and then continue adding.
func (b *GeoEventBatch) IsFull() bool {
	return len(b.events) >= types.BatchSizeMax
}

// Clear removes all events from the batch without submitting them.
//
// Use Clear to discard a batch and start over, or to reuse the batch
// after Commit for adding more events.
func (b *GeoEventBatch) Clear() {
	b.events = b.events[:0]
}

// Commit submits all accumulated events to the cluster.
//
// Events are submitted as a single batch operation. On success, the batch
// is automatically cleared. On failure, the batch remains unchanged so
// you can inspect or retry.
//
// Returns:
//   - []InsertGeoEventsError: Per-event validation errors (empty on full success)
//   - error: Network or system error (nil on success)
func (b *GeoEventBatch) Commit() ([]types.InsertGeoEventsError, error) {
	if len(b.events) == 0 {
		return nil, nil
	}

	var results []types.InsertGeoEventsError
	var err error

	if b.operation == "insert" {
		results, err = b.client.InsertEvents(b.events)
	} else {
		results, err = b.client.UpsertEvents(b.events)
	}

	if err == nil {
		b.events = b.events[:0]
	}

	return results, err
}

// ============================================================================
// Delete Entity Batch Builder
// ============================================================================

// DeleteEntityBatch provides a builder pattern for accumulating entity IDs to delete.
//
// Use for GDPR-compliant deletion of multiple entities in a single operation.
// All events associated with each entity are permanently removed.
//
// Example:
//
//	batch := client.CreateDeleteBatch()
//	for _, id := range entityIDsToDelete {
//	    batch.Add(id)
//	}
//	result, err := batch.Commit()
//	log.Printf("Deleted %d entities", result.DeletedCount)
type DeleteEntityBatch struct {
	entityIDs []types.Uint128
	client    *geoClient
}

// Add adds an entity ID to the deletion batch.
//
// Returns an error if:
//   - The batch is full (10,000 entities)
//   - The entity ID is zero
func (b *DeleteEntityBatch) Add(entityID types.Uint128) error {
	if len(b.entityIDs) >= types.BatchSizeMax {
		return BatchTooLargeError{Msg: fmt.Sprintf("batch is full (max %d entities)", types.BatchSizeMax)}
	}

	// Check for zero entity ID
	zeroID := types.ToUint128(0)
	if entityID == zeroID {
		return InvalidEntityIDError{Msg: "entity_id must not be zero"}
	}

	b.entityIDs = append(b.entityIDs, entityID)
	return nil
}

// Count returns the number of entity IDs in the batch.
func (b *DeleteEntityBatch) Count() int {
	return len(b.entityIDs)
}

// Clear removes all entity IDs from the batch without executing deletion.
func (b *DeleteEntityBatch) Clear() {
	b.entityIDs = b.entityIDs[:0]
}

// Commit executes the deletion for all accumulated entity IDs.
//
// Returns a DeleteResult containing:
//   - DeletedCount: Number of entities successfully deleted
//   - NotFoundCount: Number of entities that did not exist
//
// On success, the batch is automatically cleared.
func (b *DeleteEntityBatch) Commit() (types.DeleteResult, error) {
	if len(b.entityIDs) == 0 {
		return types.DeleteResult{}, nil
	}

	result, err := b.client.DeleteEntities(b.entityIDs)
	if err == nil {
		b.entityIDs = b.entityIDs[:0]
	}

	return result, err
}

// ============================================================================
// GeoClient Implementation
// ============================================================================

// geoClient is the concrete implementation of the GeoClient interface.
// Use NewGeoClient or NewGeoClientEcho to create instances.
type geoClient struct {
	arch_client   *C.arch_client_t
	config        GeoClientConfig
	retryConfig   RetryConfig
	metrics       *observability.SDKMetrics
	topologyCache *types.TopologyCache
	shardRouter   *types.ShardRouter
	closed        bool
}

// NewGeoClient creates a new ArcherDB geospatial client connected to a cluster.
//
// The client establishes connections to the provided addresses and discovers
// the full cluster topology. At least one address must be provided, but the
// client will automatically discover and connect to all cluster nodes.
//
// The returned client is safe for concurrent use by multiple goroutines.
// Create one client and share it across your application.
//
// Example:
//
//	client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
//	    ClusterID: types.ToUint128(0),
//	    Addresses: []string{"127.0.0.1:3001"},
//	})
//	if err != nil {
//	    log.Fatal(err)
//	}
//	defer client.Close()
//
// Returns an error if:
//   - No addresses provided
//   - Connection to all addresses fails
//   - System resources are exhausted
func NewGeoClient(config GeoClientConfig) (GeoClient, error) {
	if len(config.Addresses) == 0 {
		return nil, errors.ErrInvalidAddress{}
	}

	// Set default retry config if not provided
	retryConfig := DefaultRetryConfig()
	if config.Retry != nil {
		retryConfig = *config.Retry
	}

	// Allocate a cstring of the addresses joined with ",".
	addressesRaw := strings.Join(config.Addresses, ",")
	cAddresses := C.CString(addressesRaw)
	defer C.free(unsafe.Pointer(cAddresses))

	tbClient := new(C.arch_client_t)
	clusterID := C.arch_uint128_t(config.ClusterID)

	// Create the arch_client
	initStatus := C.arch_client_init(
		tbClient,
		(*C.uint8_t)(unsafe.Pointer(&clusterID)),
		cAddresses,
		C.uint32_t(len(addressesRaw)),
		C.uintptr_t(0), // on_completion_ctx
		(*[0]byte)(C.onGoPacketCompletion),
	)

	if initStatus != C.ARCH_INIT_SUCCESS {
		switch initStatus {
		case C.ARCH_INIT_UNEXPECTED:
			return nil, errors.ErrUnexpected{}
		case C.ARCH_INIT_OUT_OF_MEMORY:
			return nil, errors.ErrOutOfMemory{}
		case C.ARCH_INIT_ADDRESS_INVALID:
			return nil, errors.ErrInvalidAddress{}
		case C.ARCH_INIT_ADDRESS_LIMIT_EXCEEDED:
			return nil, errors.ErrAddressLimitExceeded{}
		case C.ARCH_INIT_SYSTEM_RESOURCES:
			return nil, errors.ErrSystemResources{}
		case C.ARCH_INIT_NETWORK_SUBSYSTEM:
			return nil, errors.ErrNetworkSubsystem{}
		default:
			panic("arch_client_init(): invalid error code")
		}
	}

	topologyCache := types.NewTopologyCache()
	client := &geoClient{
		arch_client:   tbClient,
		config:        config,
		retryConfig:   retryConfig,
		metrics:       observability.GetMetrics(),
		topologyCache: topologyCache,
		closed:        false,
	}
	// Initialize shard router with refresh callback
	client.shardRouter = types.NewShardRouter(topologyCache, client.RefreshTopology)
	return client, nil
}

// NewGeoClientEcho creates an echo client for testing without a running server.
//
// The echo client returns mock responses for all operations, useful for:
//   - Unit testing application logic
//   - Development without a cluster
//   - Benchmarking SDK overhead
//
// Do not use in production - data is not persisted.
func NewGeoClientEcho(config GeoClientConfig) (GeoClient, error) {
	if len(config.Addresses) == 0 {
		return nil, errors.ErrInvalidAddress{}
	}

	retryConfig := DefaultRetryConfig()
	if config.Retry != nil {
		retryConfig = *config.Retry
	}

	addressesRaw := strings.Join(config.Addresses, ",")
	cAddresses := C.CString(addressesRaw)
	defer C.free(unsafe.Pointer(cAddresses))

	tbClient := new(C.arch_client_t)
	clusterID := C.arch_uint128_t(config.ClusterID)

	initStatus := C.arch_client_init_echo(
		tbClient,
		(*C.uint8_t)(unsafe.Pointer(&clusterID)),
		cAddresses,
		C.uint32_t(len(addressesRaw)),
		C.uintptr_t(0),
		(*[0]byte)(C.onGoPacketCompletion),
	)

	if initStatus != C.ARCH_INIT_SUCCESS {
		return nil, errors.ErrUnexpected{}
	}

	topologyCache := types.NewTopologyCache()
	client := &geoClient{
		arch_client:   tbClient,
		config:        config,
		retryConfig:   retryConfig,
		metrics:       observability.GetMetrics(),
		topologyCache: topologyCache,
		closed:        false,
	}
	client.shardRouter = types.NewShardRouter(topologyCache, client.RefreshTopology)
	return client, nil
}

// Close closes the client and releases all associated resources.
//
// After Close is called, all pending operations will complete and subsequent
// operations will return ClientClosedError. It is safe to call Close multiple times.
func (c *geoClient) Close() {
	if !c.closed {
		C.arch_client_deinit(c.arch_client)
		c.closed = true
	}
}

// ============================================================================
// Native Request Handling
// ============================================================================

// doGeoRequest submits a request to the server and waits for the response.
// Uses the same request struct as arch_client.go to share the onGoPacketCompletion callback.
func (c *geoClient) doGeoRequest(op types.GeoOperation, count int, eventSize uintptr, data unsafe.Pointer) ([]uint8, error) {
	var req request
	req.ready = make(chan []uint8, 1)

	packet := new(C.arch_packet_t)
	packet.user_data = unsafe.Pointer(&req)
	packet.user_tag = 0
	packet.operation = C.uint8_t(op)
	packet.data_size = C.uint32_t(count * int(eventSize))
	packet.data = data

	// Pin all go-allocated refs accessed by onGoPacketCompletion
	var pinner runtime.Pinner
	defer pinner.Unpin()
	pinner.Pin(&req)
	pinner.Pin(packet)
	if data != nil {
		pinner.Pin(data)
	}

	clientStatus := C.arch_client_submit(c.arch_client, packet)
	if clientStatus == C.ARCH_CLIENT_INVALID {
		return nil, errors.ErrClientClosed{}
	}

	// Wait for completion
	reply := <-req.ready
	packetStatus := C.ARCH_PACKET_STATUS(packet.status)

	if packetStatus != C.ARCH_PACKET_OK {
		switch packetStatus {
		case C.ARCH_PACKET_TOO_MUCH_DATA:
			return nil, errors.ErrMaximumBatchSizeExceeded{}
		case C.ARCH_PACKET_CLIENT_EVICTED:
			return nil, errors.ErrClientEvicted{}
		case C.ARCH_PACKET_CLIENT_RELEASE_TOO_LOW:
			return nil, errors.ErrClientReleaseTooLow{}
		case C.ARCH_PACKET_CLIENT_RELEASE_TOO_HIGH:
			return nil, errors.ErrClientReleaseTooHigh{}
		case C.ARCH_PACKET_CLIENT_SHUTDOWN:
			return nil, errors.ErrClientClosed{}
		case C.ARCH_PACKET_INVALID_OPERATION:
			return nil, errors.ErrInvalidOperation{}
		case C.ARCH_PACKET_INVALID_DATA_SIZE:
			return nil, fmt.Errorf("invalid data size")
		default:
			return nil, fmt.Errorf("unknown packet status: %d", packetStatus)
		}
	}

	return reply, nil
}

// doGeoRequestBytes submits a request with raw byte data to the server.
// Used for variable-length messages like polygon queries.
func (c *geoClient) doGeoRequestBytes(op types.GeoOperation, data []byte) ([]uint8, error) {
	var req request
	req.ready = make(chan []uint8, 1)

	packet := new(C.arch_packet_t)
	packet.user_data = unsafe.Pointer(&req)
	packet.user_tag = 0
	packet.operation = C.uint8_t(op)
	packet.data_size = C.uint32_t(len(data))
	packet.data = unsafe.Pointer(&data[0])

	// Pin all go-allocated refs accessed by onGoPacketCompletion
	var pinner runtime.Pinner
	defer pinner.Unpin()
	pinner.Pin(&req)
	pinner.Pin(packet)
	pinner.Pin(&data[0])

	clientStatus := C.arch_client_submit(c.arch_client, packet)
	if clientStatus == C.ARCH_CLIENT_INVALID {
		return nil, errors.ErrClientClosed{}
	}

	// Wait for completion
	reply := <-req.ready
	packetStatus := C.ARCH_PACKET_STATUS(packet.status)

	if packetStatus != C.ARCH_PACKET_OK {
		switch packetStatus {
		case C.ARCH_PACKET_TOO_MUCH_DATA:
			return nil, errors.ErrMaximumBatchSizeExceeded{}
		case C.ARCH_PACKET_CLIENT_EVICTED:
			return nil, errors.ErrClientEvicted{}
		case C.ARCH_PACKET_CLIENT_RELEASE_TOO_LOW:
			return nil, errors.ErrClientReleaseTooLow{}
		case C.ARCH_PACKET_CLIENT_RELEASE_TOO_HIGH:
			return nil, errors.ErrClientReleaseTooHigh{}
		case C.ARCH_PACKET_CLIENT_SHUTDOWN:
			return nil, errors.ErrClientClosed{}
		case C.ARCH_PACKET_INVALID_OPERATION:
			return nil, errors.ErrInvalidOperation{}
		case C.ARCH_PACKET_INVALID_DATA_SIZE:
			return nil, fmt.Errorf("invalid data size")
		default:
			return nil, fmt.Errorf("unknown packet status: %d", packetStatus)
		}
	}

	return reply, nil
}

// CreateBatch creates a new batch builder for inserting events.
//
// Use the returned GeoEventBatch to accumulate events before submission.
// Events added via this batch will be inserted (not upserted).
func (c *geoClient) CreateBatch() *GeoEventBatch {
	return &GeoEventBatch{
		events:    make([]types.GeoEvent, 0),
		client:    c,
		operation: "insert",
	}
}

// CreateUpsertBatch creates a new batch builder for upserting events.
//
// Use the returned GeoEventBatch to accumulate events before submission.
// Events added via this batch will be upserted (insert or update).
func (c *geoClient) CreateUpsertBatch() *GeoEventBatch {
	return &GeoEventBatch{
		events:    make([]types.GeoEvent, 0),
		client:    c,
		operation: "upsert",
	}
}

// CreateDeleteBatch creates a new batch builder for deleting entities.
//
// Use the returned DeleteEntityBatch to accumulate entity IDs for deletion.
// All events associated with each entity will be permanently removed.
func (c *geoClient) CreateDeleteBatch() *DeleteEntityBatch {
	return &DeleteEntityBatch{
		entityIDs: make([]types.Uint128, 0),
		client:    c,
	}
}

func (c *geoClient) submitInsertEventsOnce(
	events []types.GeoEvent,
	operation types.GeoOperation,
) ([]types.InsertGeoEventsError, error) {
	reply, err := c.doGeoRequest(
		operation,
		len(events),
		unsafe.Sizeof(types.GeoEvent{}),
		unsafe.Pointer(&events[0]),
	)
	if err != nil {
		return nil, err
	}

	if reply == nil {
		return make([]types.InsertGeoEventsError, 0), nil
	}

	resultsCount := len(reply) / int(unsafe.Sizeof(types.InsertGeoEventsError{}))
	results := unsafe.Slice((*types.InsertGeoEventsError)(unsafe.Pointer(&reply[0])), resultsCount)
	errors := make([]types.InsertGeoEventsError, 0, len(results))
	for _, result := range results {
		if result.Result != types.InsertResultOK {
			errors = append(errors, result)
		}
	}
	return errors, nil
}

func submitInsertBatches(
	events []types.GeoEvent,
	batchSize int,
	submit func([]types.GeoEvent) ([]types.InsertGeoEventsError, error),
) ([]types.InsertGeoEventsError, error) {
	if len(events) == 0 {
		return nil, nil
	}
	if batchSize <= 0 {
		return nil, fmt.Errorf("batchSize must be positive")
	}

	allErrors := make([]types.InsertGeoEventsError, 0)
	for offset := 0; offset < len(events); offset += batchSize {
		end := offset + batchSize
		if end > len(events) {
			end = len(events)
		}
		chunk := events[offset:end]

		chunkErrors, err := submit(chunk)
		if err != nil {
			return nil, err
		}

		for _, errEntry := range chunkErrors {
			errEntry.Index += uint32(offset)
			allErrors = append(allErrors, errEntry)
		}
	}

	return allErrors, nil
}

func (c *geoClient) submitInsertEventsBatches(
	events []types.GeoEvent,
	operation types.GeoOperation,
	batchSize int,
) ([]types.InsertGeoEventsError, error) {
	return submitInsertBatches(events, batchSize, func(chunk []types.GeoEvent) ([]types.InsertGeoEventsError, error) {
		return c.withRetry(func() ([]types.InsertGeoEventsError, error) {
			return c.submitInsertEventsOnce(chunk, operation)
		})
	})
}

// InsertEvents inserts geo events.
func (c *geoClient) InsertEvents(events []types.GeoEvent) ([]types.InsertGeoEventsError, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	if len(events) == 0 {
		return nil, nil
	}

	// Prepare events (compute composite IDs)
	for i := range events {
		types.PrepareGeoEvent(&events[i])
	}

	return c.submitInsertEventsBatches(events, types.GeoOperationInsertEvents, types.BatchSizeMax)
}

// UpsertEvents upserts geo events.
func (c *geoClient) UpsertEvents(events []types.GeoEvent) ([]types.InsertGeoEventsError, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	if len(events) == 0 {
		return nil, nil
	}

	// Prepare events (compute composite IDs)
	for i := range events {
		types.PrepareGeoEvent(&events[i])
	}

	return c.submitInsertEventsBatches(events, types.GeoOperationUpsertEvents, types.BatchSizeMax)
}

// DeleteEntities deletes entities by their IDs.
func (c *geoClient) DeleteEntities(entityIDs []types.Uint128) (types.DeleteResult, error) {
	if c.closed {
		return types.DeleteResult{}, ClientClosedError{Msg: "client has been closed"}
	}

	if len(entityIDs) == 0 {
		return types.DeleteResult{}, nil
	}

	reply, err := c.doGeoRequest(
		types.GeoOperationDeleteEntities,
		len(entityIDs),
		unsafe.Sizeof(types.Uint128{}),
		unsafe.Pointer(&entityIDs[0]),
	)
	if err != nil {
		return types.DeleteResult{}, err
	}

	// Parse delete results
	if reply == nil {
		return types.DeleteResult{DeletedCount: len(entityIDs)}, nil
	}

	resultsCount := len(reply) / int(unsafe.Sizeof(types.DeleteEntitiesError{}))
	errors := unsafe.Slice((*types.DeleteEntitiesError)(unsafe.Pointer(&reply[0])), resultsCount)

	notFoundCount := 0
	for _, e := range errors {
		if e.Result == types.DeleteResultEntityNotFound {
			notFoundCount++
		}
	}

	return types.DeleteResult{
		DeletedCount:  len(entityIDs) - notFoundCount,
		NotFoundCount: notFoundCount,
	}, nil
}

// GetLatestByUUID looks up the latest event for an entity by UUID.
func (c *geoClient) GetLatestByUUID(entityID types.Uint128) (*types.GeoEvent, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	// Create query filter for UUID lookup
	filter := types.QueryUUIDFilter{
		EntityID: entityID,
	}

	reply, err := c.doGeoRequest(
		types.GeoOperationQueryUUID,
		1,
		unsafe.Sizeof(types.QueryUUIDFilter{}),
		unsafe.Pointer(&filter),
	)
	if err != nil {
		return nil, err
	}

	if reply == nil || len(reply) < 16 {
		return nil, nil
	}

	status := reply[0]
	if status == 200 {
		return nil, nil
	}
	if status == 210 {
		return nil, EntityExpiredError{Msg: "entity expired due to TTL"}
	}
	if status != 0 {
		return nil, InvalidEntityIDError{Msg: fmt.Sprintf("query_uuid status %d", status)}
	}

	eventSize := int(unsafe.Sizeof(types.GeoEvent{}))
	if len(reply) < 16+eventSize {
		return nil, nil // Response too short
	}

	// Parse GeoEvent from response body (after header)
	event := (*types.GeoEvent)(unsafe.Pointer(&reply[16]))

	// Make a copy to avoid holding reference to reply buffer
	eventCopy := *event
	return &eventCopy, nil
}

// QueryUUIDBatch looks up latest events for multiple entities.
func (c *geoClient) QueryUUIDBatch(entityIDs []types.Uint128) (types.QueryUUIDBatchResult, error) {
	if c.closed {
		return types.QueryUUIDBatchResult{}, ClientClosedError{Msg: "client has been closed"}
	}

	if len(entityIDs) > types.QueryUUIDBatchMax {
		return types.QueryUUIDBatchResult{}, BatchTooLargeError{
			Msg: fmt.Sprintf("batch exceeds %d UUIDs", types.QueryUUIDBatchMax),
		}
	}

	if len(entityIDs) == 0 {
		return types.QueryUUIDBatchResult{
			FoundCount:      0,
			NotFoundCount:   0,
			NotFoundIndices: nil,
			Events:          nil,
		}, nil
	}

	headerSize := 8
	totalSize := headerSize + len(entityIDs)*16
	data := make([]byte, totalSize)
	binary.LittleEndian.PutUint32(data[0:4], uint32(len(entityIDs)))

	offset := headerSize
	for _, id := range entityIDs {
		idBytes := id.Bytes()
		copy(data[offset:offset+16], idBytes[:])
		offset += 16
	}

	reply, err := c.doGeoRequestBytes(
		types.GeoOperationQueryUUIDBatch,
		data,
	)
	if err != nil {
		return types.QueryUUIDBatchResult{}, err
	}

	return parseQueryUUIDBatchResponse(reply)
}

// QueryRadius queries events within a radius.
func (c *geoClient) QueryRadius(filter types.QueryRadiusFilter) (types.QueryResult, error) {
	if c.closed {
		return types.QueryResult{}, ClientClosedError{Msg: "client has been closed"}
	}

	if filter.Limit > uint32(types.QueryLimitMax) {
		return types.QueryResult{}, QueryResultTooLargeError{
			Msg: fmt.Sprintf("limit %d exceeds max %d", filter.Limit, types.QueryLimitMax),
		}
	}

	reply, err := c.doGeoRequest(
		types.GeoOperationQueryRadius,
		1,
		unsafe.Sizeof(types.QueryRadiusFilter{}),
		unsafe.Pointer(&filter),
	)
	if err != nil {
		return types.QueryResult{}, err
	}

	return c.parseQueryResponse(reply, int(filter.Limit))
}

// QueryPolygon queries events within a polygon.
// The polygon can optionally contain holes (exclusion zones).
func (c *geoClient) QueryPolygon(filter types.QueryPolygonFilter) (types.QueryResult, error) {
	if c.closed {
		return types.QueryResult{}, ClientClosedError{Msg: "client has been closed"}
	}

	if filter.Limit > uint32(types.QueryLimitMax) {
		return types.QueryResult{}, QueryResultTooLargeError{
			Msg: fmt.Sprintf("limit %d exceeds max %d", filter.Limit, types.QueryLimitMax),
		}
	}

	if len(filter.Vertices) < 3 {
		return types.QueryResult{}, InvalidCoordinatesError{
			Msg: fmt.Sprintf("polygon must have at least 3 vertices, got %d", len(filter.Vertices)),
		}
	}

	if len(filter.Vertices) > types.PolygonVerticesMax {
		return types.QueryResult{}, InvalidCoordinatesError{
			Msg: fmt.Sprintf("polygon exceeds maximum %d vertices, got %d", types.PolygonVerticesMax, len(filter.Vertices)),
		}
	}

	if len(filter.Holes) > types.PolygonHolesMax {
		return types.QueryResult{}, InvalidCoordinatesError{
			Msg: fmt.Sprintf("too many holes: %d exceeds maximum %d", len(filter.Holes), types.PolygonHolesMax),
		}
	}

	// Serialize to wire format:
	// 1. QueryPolygonFilter header (128 bytes)
	// 2. Outer vertices (vertex_count * 16 bytes)
	// 3. Hole descriptors (hole_count * 8 bytes)
	// 4. Hole vertices (sum of all hole vertex counts * 16 bytes)

	// Calculate total size
	headerSize := 128 // QueryPolygonFilter header
	outerVerticesSize := len(filter.Vertices) * 16
	holeDescriptorsSize := len(filter.Holes) * 8

	totalHoleVertices := 0
	for _, hole := range filter.Holes {
		if len(hole.Vertices) < 3 {
			return types.QueryResult{}, InvalidCoordinatesError{
				Msg: fmt.Sprintf("hole must have at least 3 vertices, got %d", len(hole.Vertices)),
			}
		}
		totalHoleVertices += len(hole.Vertices)
	}
	holeVerticesSize := totalHoleVertices * 16

	totalSize := headerSize + outerVerticesSize + holeDescriptorsSize + holeVerticesSize
	data := make([]byte, totalSize)

	// Write header (little-endian)
	binary.LittleEndian.PutUint32(data[0:4], uint32(len(filter.Vertices))) // vertex_count
	binary.LittleEndian.PutUint32(data[4:8], uint32(len(filter.Holes)))    // hole_count
	binary.LittleEndian.PutUint32(data[8:12], filter.Limit)                // limit
	binary.LittleEndian.PutUint32(data[12:16], 0)                          // _reserved_align
	binary.LittleEndian.PutUint64(data[16:24], filter.TimestampMin)        // timestamp_min
	binary.LittleEndian.PutUint64(data[24:32], filter.TimestampMax)        // timestamp_max
	// Extract group_id as u64 from Uint128 (lower 8 bytes in little-endian)
	groupIDBytes := filter.GroupID.Bytes()
	copy(data[32:40], groupIDBytes[:8]) // group_id (lower 64 bits)
	// bytes 40-128 are reserved (zeroed by make)

	// Write outer vertices
	offset := headerSize
	for _, v := range filter.Vertices {
		binary.LittleEndian.PutUint64(data[offset:offset+8], uint64(v.LatNano))
		binary.LittleEndian.PutUint64(data[offset+8:offset+16], uint64(v.LonNano))
		offset += 16
	}

	// Write hole descriptors
	for _, hole := range filter.Holes {
		binary.LittleEndian.PutUint32(data[offset:offset+4], uint32(len(hole.Vertices)))
		binary.LittleEndian.PutUint32(data[offset+4:offset+8], 0) // reserved
		offset += 8
	}

	// Write hole vertices
	for _, hole := range filter.Holes {
		for _, v := range hole.Vertices {
			binary.LittleEndian.PutUint64(data[offset:offset+8], uint64(v.LatNano))
			binary.LittleEndian.PutUint64(data[offset+8:offset+16], uint64(v.LonNano))
			offset += 16
		}
	}

	// Submit request with raw byte data
	reply, err := c.doGeoRequestBytes(types.GeoOperationQueryPolygon, data)
	if err != nil {
		return types.QueryResult{}, err
	}

	return c.parseQueryResponse(reply, int(filter.Limit))
}

// QueryLatest queries the most recent events globally or by group.
func (c *geoClient) QueryLatest(filter types.QueryLatestFilter) (types.QueryResult, error) {
	if c.closed {
		return types.QueryResult{}, ClientClosedError{Msg: "client has been closed"}
	}

	if filter.Limit > uint32(types.QueryLimitMax) {
		return types.QueryResult{}, QueryResultTooLargeError{
			Msg: fmt.Sprintf("limit %d exceeds max %d", filter.Limit, types.QueryLimitMax),
		}
	}

	reply, err := c.doGeoRequest(
		types.GeoOperationQueryLatest,
		1,
		unsafe.Sizeof(types.QueryLatestFilter{}),
		unsafe.Pointer(&filter),
	)
	if err != nil {
		return types.QueryResult{}, err
	}

	return c.parseQueryResponse(reply, int(filter.Limit))
}

// Ping sends a ping to verify server connectivity.
func (c *geoClient) Ping() (bool, error) {
	if c.closed {
		return false, ClientClosedError{Msg: "client has been closed"}
	}

	request := types.PingRequest{
		PingData: 0x676e6970, // "ping"
	}
	reply, err := c.doGeoRequest(
		types.GeoOperationPing,
		1,
		unsafe.Sizeof(types.PingRequest{}),
		unsafe.Pointer(&request),
	)
	if err != nil {
		return false, err
	}

	if reply == nil || len(reply) < int(unsafe.Sizeof(types.PingResponse{})) {
		return true, nil
	}

	pong := (*types.PingResponse)(unsafe.Pointer(&reply[0]))
	return pong.Pong == 0x676e6f70, nil
}

// GetStatus returns current server status.
func (c *geoClient) GetStatus() (types.StatusResponse, error) {
	if c.closed {
		return types.StatusResponse{}, ClientClosedError{Msg: "client has been closed"}
	}

	request := types.StatusRequest{Reserved: 0}
	reply, err := c.doGeoRequest(
		types.GeoOperationGetStatus,
		1,
		unsafe.Sizeof(types.StatusRequest{}),
		unsafe.Pointer(&request),
	)
	if err != nil {
		return types.StatusResponse{}, err
	}

	if reply == nil || len(reply) < int(unsafe.Sizeof(types.StatusResponse{})) {
		return types.StatusResponse{}, nil
	}

	status := (*types.StatusResponse)(unsafe.Pointer(&reply[0]))
	return *status, nil
}

// ============================================================================
// Topology Discovery (F5.1 Smart Client)
// ============================================================================

// GetTopology fetches the current cluster topology from the server.
func (c *geoClient) GetTopology() (*types.TopologyResponse, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	request := types.TopologyRequest{Reserved: 0}
	reply, err := c.doGeoRequest(
		types.GeoOperationGetTopology,
		1,
		unsafe.Sizeof(types.TopologyRequest{}),
		unsafe.Pointer(&request),
	)
	if err != nil {
		return nil, err
	}

	if reply == nil || len(reply) == 0 {
		return nil, fmt.Errorf("empty topology response")
	}

	// Parse topology response from wire format
	topology, err := c.parseTopologyResponse(reply)
	if err != nil {
		return nil, err
	}

	// Update cache
	c.topologyCache.Update(topology)

	return topology, nil
}

// parseTopologyResponse parses a topology response from wire format.
func (c *geoClient) parseTopologyResponse(reply []uint8) (*types.TopologyResponse, error) {
	// Minimum size: version(8) + num_shards(4) + cluster_id(16) + last_change_ns(16) +
	//               resharding_status(1) + flags(1) + padding(6) = 52 bytes header
	if len(reply) < 52 {
		return nil, fmt.Errorf("topology response too short: %d bytes", len(reply))
	}

	topology := &types.TopologyResponse{}

	// Parse header
	topology.Version = binary.LittleEndian.Uint64(reply[0:8])
	topology.NumShards = binary.LittleEndian.Uint32(reply[8:12])

	// Parse cluster_id (16 bytes at offset 12)
	var clusterIDBytes [16]byte
	copy(clusterIDBytes[:], reply[12:28])
	topology.ClusterID = types.BytesToUint128(clusterIDBytes)

	// Parse last_change_ns (16 bytes at offset 28, we use first 8 as int64)
	topology.LastChangeNs = int64(binary.LittleEndian.Uint64(reply[28:36]))

	// Parse resharding_status (1 byte at offset 44)
	topology.ReshardingStatus = reply[44]

	// Parse shards (each shard info follows header)
	// ShardInfo wire format: id(4) + primary(64) + replicas(64*6) + replica_count(1) +
	//                       status(1) + entity_count(8) + size_bytes(8) = 470 bytes
	const shardInfoSize = 470
	const headerSize = 52

	expectedSize := headerSize + int(topology.NumShards)*shardInfoSize
	if len(reply) < expectedSize {
		// Simplified response format - just header with shard count
		// Create minimal shard info
		topology.Shards = make([]types.ShardInfo, topology.NumShards)
		for i := uint32(0); i < topology.NumShards; i++ {
			topology.Shards[i] = types.ShardInfo{
				ID:     i,
				Status: types.ShardActive,
			}
		}
		return topology, nil
	}

	// Parse full shard info
	topology.Shards = make([]types.ShardInfo, topology.NumShards)
	offset := headerSize
	for i := uint32(0); i < topology.NumShards; i++ {
		shard := &topology.Shards[i]
		shard.ID = binary.LittleEndian.Uint32(reply[offset : offset+4])
		offset += 4

		// Parse primary address (64 bytes, null-terminated)
		primaryEnd := offset + 64
		shard.Primary = strings.TrimRight(string(reply[offset:primaryEnd]), "\x00")
		offset = primaryEnd

		// Parse replicas (6 * 64 bytes)
		shard.Replicas = make([]string, 0, 6)
		for j := 0; j < 6; j++ {
			replicaEnd := offset + 64
			replica := strings.TrimRight(string(reply[offset:replicaEnd]), "\x00")
			if replica != "" {
				shard.Replicas = append(shard.Replicas, replica)
			}
			offset = replicaEnd
		}

		// Skip replica_count (1 byte) - we derive from parsed replicas
		offset++

		// Parse status (1 byte)
		shard.Status = types.ShardStatus(reply[offset])
		offset++

		// Parse entity_count (8 bytes)
		shard.EntityCount = binary.LittleEndian.Uint64(reply[offset : offset+8])
		offset += 8

		// Parse size_bytes (8 bytes)
		shard.SizeBytes = binary.LittleEndian.Uint64(reply[offset : offset+8])
		offset += 8
	}

	return topology, nil
}

// GetTopologyCache returns the topology cache for direct access.
func (c *geoClient) GetTopologyCache() *types.TopologyCache {
	return c.topologyCache
}

// RefreshTopology forces a topology refresh from the cluster.
func (c *geoClient) RefreshTopology() error {
	c.topologyCache.Invalidate()
	_, err := c.GetTopology()
	return err
}

// GetShardRouter returns a shard router for shard-aware operations.
func (c *geoClient) GetShardRouter() *types.ShardRouter {
	return c.shardRouter
}

// ============================================================================
// TTL Operations (Manual TTL Support)
// ============================================================================

// SetTTL sets an absolute TTL for an entity.
func (c *geoClient) SetTTL(entityID types.Uint128, ttlSeconds uint32) (*types.TtlSetResponse, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	request := types.TtlSetRequest{
		EntityID:   entityID,
		TTLSeconds: ttlSeconds,
	}

	reply, err := c.doGeoRequest(
		types.GeoOperationTTLSet,
		1,
		unsafe.Sizeof(types.TtlSetRequest{}),
		unsafe.Pointer(&request),
	)
	if err != nil {
		return nil, err
	}

	if reply == nil || len(reply) < int(unsafe.Sizeof(types.TtlSetResponse{})) {
		return nil, fmt.Errorf("invalid TTL set response")
	}

	response := (*types.TtlSetResponse)(unsafe.Pointer(&reply[0]))
	responseCopy := *response
	return &responseCopy, nil
}

// ExtendTTL extends an entity's TTL by a relative amount.
func (c *geoClient) ExtendTTL(entityID types.Uint128, extendBySeconds uint32) (*types.TtlExtendResponse, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	request := types.TtlExtendRequest{
		EntityID:        entityID,
		ExtendBySeconds: extendBySeconds,
	}

	reply, err := c.doGeoRequest(
		types.GeoOperationTTLExtend,
		1,
		unsafe.Sizeof(types.TtlExtendRequest{}),
		unsafe.Pointer(&request),
	)
	if err != nil {
		return nil, err
	}

	if reply == nil || len(reply) < int(unsafe.Sizeof(types.TtlExtendResponse{})) {
		return nil, fmt.Errorf("invalid TTL extend response")
	}

	response := (*types.TtlExtendResponse)(unsafe.Pointer(&reply[0]))
	responseCopy := *response
	return &responseCopy, nil
}

// ClearTTL removes an entity's TTL, making it never expire.
func (c *geoClient) ClearTTL(entityID types.Uint128) (*types.TtlClearResponse, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	request := types.TtlClearRequest{
		EntityID: entityID,
	}

	reply, err := c.doGeoRequest(
		types.GeoOperationTTLClear,
		1,
		unsafe.Sizeof(types.TtlClearRequest{}),
		unsafe.Pointer(&request),
	)
	if err != nil {
		return nil, err
	}

	if reply == nil || len(reply) < int(unsafe.Sizeof(types.TtlClearResponse{})) {
		return nil, fmt.Errorf("invalid TTL clear response")
	}

	response := (*types.TtlClearResponse)(unsafe.Pointer(&reply[0]))
	responseCopy := *response
	return &responseCopy, nil
}

// parseQueryResponse parses a query response into QueryResult.
// Handles QueryResponse headers when present, with a fallback for legacy raw GeoEvent arrays.
func (c *geoClient) parseQueryResponse(reply []uint8, limit int) (types.QueryResult, error) {
	if reply == nil || len(reply) == 0 {
		return types.QueryResult{Events: nil, HasMore: false, Cursor: 0}, nil
	}

	eventSize := int(unsafe.Sizeof(types.GeoEvent{}))
	headerSize := int(unsafe.Sizeof(types.QueryResponse{}))

	if len(reply) >= headerSize && (len(reply)-headerSize)%eventSize == 0 {
		if len(reply) == headerSize {
			hasMore := reply[4] != 0
			return types.QueryResult{Events: nil, HasMore: hasMore, Cursor: 0}, nil
		}

		count := int(binary.LittleEndian.Uint32(reply[0:4]))
		hasMore := reply[4] != 0
		data := reply[headerSize:]

		if len(data)%eventSize != 0 {
			return types.QueryResult{}, fmt.Errorf("query response payload size %d not aligned to GeoEvent size %d", len(data), eventSize)
		}

		available := len(data) / eventSize
		if count != available {
			return types.QueryResult{}, fmt.Errorf("query response count %d does not match payload events %d", count, available)
		}

		if count == 0 {
			return types.QueryResult{Events: nil, HasMore: hasMore, Cursor: 0}, nil
		}

		events := unsafe.Slice((*types.GeoEvent)(unsafe.Pointer(&data[0])), count)
		eventsCopy := make([]types.GeoEvent, count)
		copy(eventsCopy, events)

		cursor := eventsCopy[count-1].Timestamp
		return types.QueryResult{
			Events:  eventsCopy,
			HasMore: hasMore,
			Cursor:  cursor,
		}, nil
	}

	if len(reply) < eventSize {
		return types.QueryResult{Events: nil, HasMore: false, Cursor: 0}, nil
	}

	// Legacy response format: raw GeoEvent array (no header).
	eventCount := len(reply) / eventSize
	if len(reply)%eventSize != 0 {
		return types.QueryResult{}, fmt.Errorf("response size %d not aligned to GeoEvent size %d", len(reply), eventSize)
	}

	// Parse events directly from reply buffer
	events := unsafe.Slice((*types.GeoEvent)(unsafe.Pointer(&reply[0])), eventCount)

	// Copy events to avoid holding reference to reply buffer
	eventsCopy := make([]types.GeoEvent, eventCount)
	copy(eventsCopy, events)

	// Get cursor from last event's timestamp for pagination
	var cursor uint64
	if eventCount > 0 {
		cursor = eventsCopy[eventCount-1].Timestamp
	}

	// Infer has_more from whether we got exactly the requested limit
	hasMore := eventCount == limit

	return types.QueryResult{
		Events:  eventsCopy,
		HasMore: hasMore,
		Cursor:  cursor,
	}, nil
}

func parseQueryUUIDBatchResponse(reply []uint8) (types.QueryUUIDBatchResult, error) {
	if reply == nil || len(reply) == 0 {
		return types.QueryUUIDBatchResult{
			FoundCount:      0,
			NotFoundCount:   0,
			NotFoundIndices: nil,
			Events:          nil,
		}, nil
	}

	const headerSize = 16
	if len(reply) < headerSize {
		return types.QueryUUIDBatchResult{}, fmt.Errorf("query_uuid_batch response too small: %d", len(reply))
	}

	foundCount := binary.LittleEndian.Uint32(reply[0:4])
	notFoundCount := binary.LittleEndian.Uint32(reply[4:8])

	indicesSize := int(notFoundCount) * 2
	indicesEnd := headerSize + indicesSize
	eventsOffset := indicesEnd
	if rem := eventsOffset % 16; rem != 0 {
		eventsOffset += 16 - rem
	}

	eventSize := int(unsafe.Sizeof(types.GeoEvent{}))
	eventsSize := int(foundCount) * eventSize

	if len(reply) < eventsOffset+eventsSize {
		return types.QueryUUIDBatchResult{}, fmt.Errorf("query_uuid_batch response truncated: %d", len(reply))
	}

	notFoundIndices := make([]uint16, int(notFoundCount))
	for i := 0; i < int(notFoundCount); i++ {
		start := headerSize + i*2
		notFoundIndices[i] = binary.LittleEndian.Uint16(reply[start : start+2])
	}

	events := make([]types.GeoEvent, int(foundCount))
	if foundCount > 0 {
		rawEvents := unsafe.Slice((*types.GeoEvent)(unsafe.Pointer(&reply[eventsOffset])), int(foundCount))
		copy(events, rawEvents)
	}

	return types.QueryUUIDBatchResult{
		FoundCount:      foundCount,
		NotFoundCount:   notFoundCount,
		NotFoundIndices: notFoundIndices,
		Events:          events,
	}, nil
}

// ============================================================================
// Retry Logic (per client-retry spec)
// ============================================================================

func (c *geoClient) withRetry(operation func() ([]types.InsertGeoEventsError, error)) ([]types.InsertGeoEventsError, error) {
	if !c.retryConfig.Enabled {
		return operation()
	}

	startTime := time.Now()
	maxAttempts := c.retryConfig.MaxRetries + 1
	var lastError error

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		// Record retry metric for actual retry attempts (not first attempt)
		// Per client-retry/spec.md: metrics recorded during retry operations
		if attempt > 1 && c.metrics != nil {
			c.metrics.RecordRetry()
		}

		// Check total timeout
		if time.Since(startTime) >= c.retryConfig.TotalTimeout {
			if c.metrics != nil {
				c.metrics.RecordRetryExhausted()
			}
			return nil, RetryExhaustedError{Attempts: attempt - 1, LastError: lastError}
		}

		result, err := operation()
		if err == nil {
			return result, nil
		}

		lastError = err

		// Non-retryable errors fail immediately
		if geoErr, ok := err.(GeoError); ok && !geoErr.Retryable() {
			return nil, err
		}

		// Last attempt - don't sleep
		if attempt >= maxAttempts {
			break
		}

		// Calculate delay for next attempt
		delay := calculateRetryDelay(attempt+1, c.retryConfig)

		// Check if delay would exceed total timeout
		if time.Since(startTime)+delay >= c.retryConfig.TotalTimeout {
			break
		}

		time.Sleep(delay)
	}

	// All retries exhausted - record exhaustion metric
	if c.metrics != nil {
		c.metrics.RecordRetryExhausted()
	}
	return nil, RetryExhaustedError{Attempts: maxAttempts, LastError: lastError}
}

func calculateRetryDelay(attempt int, config RetryConfig) time.Duration {
	// First attempt is immediate
	if attempt <= 1 {
		return 0
	}

	// Exponential backoff: base_delay * 2^(attempt-2)
	baseDelay := config.BaseBackoff * time.Duration(1<<(attempt-2))
	delay := baseDelay
	if delay > config.MaxBackoff {
		delay = config.MaxBackoff
	}

	if !config.Jitter {
		return delay
	}

	// Jitter: random(0, delay / 2)
	jitter := time.Duration(rand.Int63n(int64(delay / 2)))
	return delay + jitter
}

// ============================================================================
// Validation
// ============================================================================

func validateGeoEvent(event types.GeoEvent) error {
	// Validate entity_id
	zeroID := types.ToUint128(0)
	if event.EntityID == zeroID {
		return InvalidEntityIDError{Msg: "entity_id must not be zero"}
	}

	// Validate latitude (-90 to +90 degrees = -90e9 to +90e9 nanodegrees)
	if event.LatNano < -90_000_000_000 || event.LatNano > 90_000_000_000 {
		return InvalidCoordinatesError{Msg: fmt.Sprintf("latitude %d out of range [-90e9, +90e9]", event.LatNano)}
	}

	// Validate longitude (-180 to +180 degrees = -180e9 to +180e9 nanodegrees)
	if event.LonNano < -180_000_000_000 || event.LonNano > 180_000_000_000 {
		return InvalidCoordinatesError{Msg: fmt.Sprintf("longitude %d out of range [-180e9, +180e9]", event.LonNano)}
	}

	// Validate heading (0-36000 centidegrees)
	if event.HeadingCdeg > 36000 {
		return InvalidCoordinatesError{Msg: fmt.Sprintf("heading %d out of range [0, 36000]", event.HeadingCdeg)}
	}

	return nil
}

// ============================================================================
// Batch Helpers (per client-retry spec)
// ============================================================================

// SplitBatch splits a slice of items into smaller chunks of the specified size.
//
// Useful for splitting large datasets into batches that fit within the 10,000 event limit.
//
// Example:
//
//	chunks := archerdb.SplitBatch(events, 8000)
//	for _, chunk := range chunks {
//	    errors, err := client.InsertEvents(chunk)
//	    // Handle results
//	}
func SplitBatch[T any](items []T, chunkSize int) [][]T {
	if chunkSize <= 0 {
		panic("chunkSize must be greater than 0")
	}

	if len(items) == 0 {
		return nil
	}

	chunks := make([][]T, 0, (len(items)+chunkSize-1)/chunkSize)
	for i := 0; i < len(items); i += chunkSize {
		end := i + chunkSize
		if end > len(items) {
			end = len(items)
		}
		chunks = append(chunks, items[i:end])
	}

	return chunks
}
