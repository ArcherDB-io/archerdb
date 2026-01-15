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

// GeoError is the base interface for ArcherDB errors.
type GeoError interface {
	error
	Code() int
	Retryable() bool
}

// ConnectionFailedError indicates failure to establish connection to cluster.
type ConnectionFailedError struct{ Msg string }
func (e ConnectionFailedError) Error() string   { return e.Msg }
func (e ConnectionFailedError) Code() int       { return 1001 }
func (e ConnectionFailedError) Retryable() bool { return true }

// ConnectionTimeoutError indicates connection attempt timed out.
type ConnectionTimeoutError struct{ Msg string }
func (e ConnectionTimeoutError) Error() string   { return e.Msg }
func (e ConnectionTimeoutError) Code() int       { return 1002 }
func (e ConnectionTimeoutError) Retryable() bool { return true }

// ClusterUnavailableError indicates cluster is unavailable after exhausting retries.
type ClusterUnavailableError struct{ Msg string }
func (e ClusterUnavailableError) Error() string   { return e.Msg }
func (e ClusterUnavailableError) Code() int       { return 2001 }
func (e ClusterUnavailableError) Retryable() bool { return true }

// InvalidCoordinatesError indicates coordinates are out of valid range.
type InvalidCoordinatesError struct{ Msg string }
func (e InvalidCoordinatesError) Error() string   { return e.Msg }
func (e InvalidCoordinatesError) Code() int       { return 3001 }
func (e InvalidCoordinatesError) Retryable() bool { return false }

// BatchTooLargeError indicates batch exceeds maximum size.
type BatchTooLargeError struct{ Msg string }
func (e BatchTooLargeError) Error() string   { return e.Msg }
func (e BatchTooLargeError) Code() int       { return 3003 }
func (e BatchTooLargeError) Retryable() bool { return false }

// InvalidEntityIDError indicates entity ID is invalid.
type InvalidEntityIDError struct{ Msg string }
func (e InvalidEntityIDError) Error() string   { return e.Msg }
func (e InvalidEntityIDError) Code() int       { return 3004 }
func (e InvalidEntityIDError) Retryable() bool { return false }

// OperationTimeoutError indicates operation timed out.
type OperationTimeoutError struct{ Msg string }
func (e OperationTimeoutError) Error() string   { return e.Msg }
func (e OperationTimeoutError) Code() int       { return 4001 }
func (e OperationTimeoutError) Retryable() bool { return true }

// QueryResultTooLargeError indicates query limit exceeds maximum.
type QueryResultTooLargeError struct{ Msg string }
func (e QueryResultTooLargeError) Error() string   { return e.Msg }
func (e QueryResultTooLargeError) Code() int       { return 4002 }
func (e QueryResultTooLargeError) Retryable() bool { return false }

// ClientClosedError indicates client has been closed.
type ClientClosedError struct{ Msg string }
func (e ClientClosedError) Error() string   { return e.Msg }
func (e ClientClosedError) Code() int       { return 5001 }
func (e ClientClosedError) Retryable() bool { return false }

// RetryExhaustedError indicates all retry attempts have been exhausted.
type RetryExhaustedError struct {
	Attempts  int
	LastError error
}
func (e RetryExhaustedError) Error() string {
	return fmt.Sprintf("all %d retry attempts exhausted, last error: %v", e.Attempts, e.LastError)
}
func (e RetryExhaustedError) Code() int       { return 5002 }
func (e RetryExhaustedError) Retryable() bool { return false }

// ============================================================================
// Configuration
// ============================================================================

// RetryConfig contains retry configuration options (per client-retry/spec.md).
type RetryConfig struct {
	Enabled        bool          // Whether automatic retry is enabled (default: true)
	MaxRetries     int           // Maximum retry attempts after initial failure (default: 5)
	BaseBackoff    time.Duration // Base backoff delay (default: 100ms)
	MaxBackoff     time.Duration // Maximum backoff delay (default: 1600ms)
	TotalTimeout   time.Duration // Total timeout for all retry attempts (default: 30s)
	Jitter         bool          // Add random jitter to prevent thundering herd (default: true)
}

// DefaultRetryConfig returns the default retry configuration.
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

// GeoClientConfig contains client configuration options.
type GeoClientConfig struct {
	ClusterID      types.Uint128
	Addresses      []string
	ConnectTimeout time.Duration
	RequestTimeout time.Duration
	Retry          *RetryConfig
}

// ============================================================================
// GeoClient Interface
// ============================================================================

// GeoClient is the ArcherDB geospatial client interface.
type GeoClient interface {
	// InsertEvents inserts geo events (returns only errors, success = empty slice).
	InsertEvents(events []types.GeoEvent) ([]types.InsertGeoEventsError, error)

	// UpsertEvents upserts geo events (update if exists, insert otherwise).
	UpsertEvents(events []types.GeoEvent) ([]types.InsertGeoEventsError, error)

	// DeleteEntities deletes entities by their IDs.
	DeleteEntities(entityIDs []types.Uint128) (types.DeleteResult, error)

	// GetLatestByUUID looks up the latest event for an entity by UUID.
	GetLatestByUUID(entityID types.Uint128) (*types.GeoEvent, error)

	// QueryRadius queries events within a radius.
	QueryRadius(filter types.QueryRadiusFilter) (types.QueryResult, error)

	// QueryPolygon queries events within a polygon.
	QueryPolygon(filter types.QueryPolygonFilter) (types.QueryResult, error)

	// QueryLatest queries the most recent events globally or by group.
	QueryLatest(filter types.QueryLatestFilter) (types.QueryResult, error)

	// Ping sends a ping to verify server connectivity.
	Ping() (bool, error)

	// GetStatus returns current server status.
	GetStatus() (types.StatusResponse, error)

	// GetTopology fetches the current cluster topology (F5.1).
	GetTopology() (*types.TopologyResponse, error)

	// GetTopologyCache returns the topology cache for direct access (F5.1).
	GetTopologyCache() *types.TopologyCache

	// RefreshTopology forces a topology refresh from the cluster (F5.1).
	RefreshTopology() error

	// GetShardRouter returns a shard router for shard-aware operations (F5.1.4).
	GetShardRouter() *types.ShardRouter

	// SetTTL sets an absolute TTL for an entity (v2.1 Manual TTL Support).
	SetTTL(entityID types.Uint128, ttlSeconds uint32) (*types.TtlSetResponse, error)

	// ExtendTTL extends an entity's TTL by a relative amount (v2.1 Manual TTL Support).
	ExtendTTL(entityID types.Uint128, extendBySeconds uint32) (*types.TtlExtendResponse, error)

	// ClearTTL removes an entity's TTL, making it never expire (v2.1 Manual TTL Support).
	ClearTTL(entityID types.Uint128) (*types.TtlClearResponse, error)

	// Close closes the client and releases resources.
	Close()
}

// ============================================================================
// GeoEvent Batch Builder
// ============================================================================

// GeoEventBatch accumulates events before commit.
type GeoEventBatch struct {
	events    []types.GeoEvent
	client    *geoClient
	operation string // "insert" or "upsert"
}

// Add adds a GeoEvent to the batch.
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

// AddFromOptions adds a GeoEvent using user-friendly options.
func (b *GeoEventBatch) AddFromOptions(opts types.GeoEventOptions) error {
	event, err := types.NewGeoEvent(opts)
	if err != nil {
		return err
	}
	return b.Add(event)
}

// Count returns the number of events in the batch.
func (b *GeoEventBatch) Count() int {
	return len(b.events)
}

// IsFull returns true if the batch is full.
func (b *GeoEventBatch) IsFull() bool {
	return len(b.events) >= types.BatchSizeMax
}

// Clear clears all events from the batch.
func (b *GeoEventBatch) Clear() {
	b.events = b.events[:0]
}

// Commit commits the batch to the cluster.
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

// DeleteEntityBatch accumulates entity IDs for deletion.
type DeleteEntityBatch struct {
	entityIDs []types.Uint128
	client    *geoClient
}

// Add adds an entity ID for deletion.
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

// Count returns the number of entities in the batch.
func (b *DeleteEntityBatch) Count() int {
	return len(b.entityIDs)
}

// Clear clears all entity IDs from the batch.
func (b *DeleteEntityBatch) Clear() {
	b.entityIDs = b.entityIDs[:0]
}

// Commit commits the delete batch.
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

type geoClient struct {
	arch_client   *C.arch_client_t
	config        GeoClientConfig
	retryConfig   RetryConfig
	metrics       *observability.SDKMetrics
	topologyCache *types.TopologyCache
	shardRouter   *types.ShardRouter
	closed        bool
}

// NewGeoClient creates a new ArcherDB geospatial client.
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

// Close closes the client and releases resources.
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

// CreateBatch creates a new batch for inserting events.
func (c *geoClient) CreateBatch() *GeoEventBatch {
	return &GeoEventBatch{
		events:    make([]types.GeoEvent, 0),
		client:    c,
		operation: "insert",
	}
}

// CreateUpsertBatch creates a new batch for upserting events.
func (c *geoClient) CreateUpsertBatch() *GeoEventBatch {
	return &GeoEventBatch{
		events:    make([]types.GeoEvent, 0),
		client:    c,
		operation: "upsert",
	}
}

// CreateDeleteBatch creates a new batch for deleting entities.
func (c *geoClient) CreateDeleteBatch() *DeleteEntityBatch {
	return &DeleteEntityBatch{
		entityIDs: make([]types.Uint128, 0),
		client:    c,
	}
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

	return c.withRetry(func() ([]types.InsertGeoEventsError, error) {
		reply, err := c.doGeoRequest(
			types.GeoOperationInsertEvents,
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

		// Parse results
		resultsCount := len(reply) / int(unsafe.Sizeof(types.InsertGeoEventsError{}))
		results := unsafe.Slice((*types.InsertGeoEventsError)(unsafe.Pointer(&reply[0])), resultsCount)
		return results, nil
	})
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

	return c.withRetry(func() ([]types.InsertGeoEventsError, error) {
		reply, err := c.doGeoRequest(
			types.GeoOperationUpsertEvents,
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
		return results, nil
	})
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
// Note: query_uuid returns raw GeoEvent directly (no QueryResponse header).
func (c *geoClient) GetLatestByUUID(entityID types.Uint128) (*types.GeoEvent, error) {
	if c.closed {
		return nil, ClientClosedError{Msg: "client has been closed"}
	}

	// Create query filter for UUID lookup
	filter := types.QueryUUIDFilter{
		EntityID: entityID,
		Limit:    1,
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

	// query_uuid returns raw GeoEvent (no header): 0 bytes if not found, 128 bytes if found
	if reply == nil || len(reply) == 0 {
		return nil, nil // Not found
	}

	eventSize := int(unsafe.Sizeof(types.GeoEvent{}))
	if len(reply) < eventSize {
		return nil, nil // Response too short
	}

	// Parse raw GeoEvent directly (no QueryResponse header)
	event := (*types.GeoEvent)(unsafe.Pointer(&reply[0]))

	// Make a copy to avoid holding reference to reply buffer
	eventCopy := *event
	return &eventCopy, nil
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
	binary.LittleEndian.PutUint32(data[0:4], uint32(len(filter.Vertices)))  // vertex_count
	binary.LittleEndian.PutUint32(data[4:8], uint32(len(filter.Holes)))     // hole_count
	binary.LittleEndian.PutUint32(data[8:12], filter.Limit)                  // limit
	binary.LittleEndian.PutUint32(data[12:16], 0)                            // _reserved_align
	binary.LittleEndian.PutUint64(data[16:24], filter.TimestampMin)          // timestamp_min
	binary.LittleEndian.PutUint64(data[24:32], filter.TimestampMax)          // timestamp_max
	// Extract group_id as u64 from Uint128 (lower 8 bytes in little-endian)
	groupIDBytes := filter.GroupID.Bytes()
	copy(data[32:40], groupIDBytes[:8])  // group_id (lower 64 bits)
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

	// Send empty ping request
	var dummy [1]byte
	_, err := c.doGeoRequest(
		types.GeoOperationPing,
		1,
		1,
		unsafe.Pointer(&dummy[0]),
	)
	if err != nil {
		return false, err
	}

	return true, nil
}

// GetStatus returns current server status.
func (c *geoClient) GetStatus() (types.StatusResponse, error) {
	if c.closed {
		return types.StatusResponse{}, ClientClosedError{Msg: "client has been closed"}
	}

	// Send empty status request
	var dummy [1]byte
	reply, err := c.doGeoRequest(
		types.GeoOperationGetStatus,
		1,
		1,
		unsafe.Pointer(&dummy[0]),
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

	// Send empty topology request
	var dummy [1]byte
	reply, err := c.doGeoRequest(
		types.GeoOperationGetTopology,
		1,
		1,
		unsafe.Pointer(&dummy[0]),
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
// TTL Operations (v2.1 Manual TTL Support)
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
// The production state_machine.zig returns raw GeoEvent array without QueryResponse header.
func (c *geoClient) parseQueryResponse(reply []uint8, limit int) (types.QueryResult, error) {
	if reply == nil || len(reply) == 0 {
		return types.QueryResult{Events: nil, HasMore: false, Cursor: 0}, nil
	}

	// Response format: raw GeoEvent array (no header in production state machine)
	eventSize := int(unsafe.Sizeof(types.GeoEvent{}))
	if len(reply) < eventSize {
		// Response too short for even one event
		return types.QueryResult{Events: nil, HasMore: false, Cursor: 0}, nil
	}

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

// SplitBatch splits a list of items into smaller chunks for retry scenarios.
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
