package archerdb

/*
#cgo CFLAGS: -g -Wall
#cgo darwin,arm64 LDFLAGS: ${SRCDIR}/pkg/native/libtb_client_aarch64-macos.a -ldl -lm
#cgo darwin,amd64 LDFLAGS: ${SRCDIR}/pkg/native/libtb_client_x86_64-macos.a -ldl -lm
#cgo linux,arm64 LDFLAGS: ${SRCDIR}/pkg/native/libtb_client_aarch64-linux.a -ldl -lm
#cgo linux,amd64 LDFLAGS: ${SRCDIR}/pkg/native/libtb_client_x86_64-linux.a -ldl -lm
#cgo windows,amd64 LDFLAGS: -L${SRCDIR}/pkg/native -ltb_client_x86_64-windows -lws2_32 -lntdll

#include <stdlib.h>
#include <string.h>
#include "./pkg/native/tb_client.h"

#ifndef __declspec
	#define __declspec(x)
#endif

typedef const uint8_t* tb_result_bytes_t;

extern __declspec(dllexport) void onGoPacketCompletion(
	uintptr_t ctx,
	tb_packet_t* packet,
	uint64_t timestamp,
	tb_result_bytes_t result_ptr,
	uint32_t result_len
);
*/
import "C"
import (
	"unsafe"

	_ "github.com/archerdb/archerdb-go/pkg/native"
	"github.com/archerdb/archerdb-go/pkg/types"
)

///////////////////////////////////////////////////////////////
// Shared Infrastructure for GeoClient
// This file provides CGO bindings and callback infrastructure
// used by geo_client.go.
//
// NOTE: ArcherDB is a geospatial database only.
// Legacy TigerBeetle financial operations are not supported.
///////////////////////////////////////////////////////////////

// request is the shared request struct used by GeoClient for
// async completion handling.
type request struct {
	ready chan []uint8
}

// getEventSize returns the size of the event structure for a given operation.
// This is used by onGoPacketCompletion to validate result sizes.
// Only geospatial operations are supported.
func getEventSize(op C.TB_OPERATION) uintptr {
	switch op {
	// GeoClient operations
	case C.TB_OPERATION_INSERT_EVENTS, C.TB_OPERATION_UPSERT_EVENTS:
		return unsafe.Sizeof(types.GeoEvent{})
	case C.TB_OPERATION_DELETE_ENTITIES:
		return unsafe.Sizeof(types.Uint128{})
	case C.TB_OPERATION_QUERY_UUID:
		return unsafe.Sizeof(types.QueryUUIDFilter{})
	case C.TB_OPERATION_QUERY_LATEST:
		return unsafe.Sizeof(types.QueryLatestFilter{})
	case C.TB_OPERATION_QUERY_RADIUS:
		return 1 // Variable-size filter
	case C.TB_OPERATION_QUERY_POLYGON:
		return 1 // Variable-size filter
	case C.TB_OPERATION_ARCHERDB_PING, C.TB_OPERATION_ARCHERDB_GET_STATUS:
		return 1 // Single byte placeholder
	default:
		return 1 // Return 1 for unknown ops to avoid divide by zero
	}
}

// getResultSize returns the size of the result structure for a given operation.
// Only geospatial operations are supported.
func getResultSize(op C.TB_OPERATION) uintptr {
	switch op {
	// GeoClient operations - results vary by operation
	case C.TB_OPERATION_INSERT_EVENTS, C.TB_OPERATION_UPSERT_EVENTS:
		return unsafe.Sizeof(types.InsertGeoEventsError{})
	case C.TB_OPERATION_DELETE_ENTITIES:
		return unsafe.Sizeof(types.DeleteEntitiesError{})
	case C.TB_OPERATION_QUERY_UUID, C.TB_OPERATION_QUERY_LATEST,
		C.TB_OPERATION_QUERY_RADIUS, C.TB_OPERATION_QUERY_POLYGON:
		return 1 // Variable-size response (QueryResponse header + GeoEvents)
	case C.TB_OPERATION_ARCHERDB_PING:
		return 1
	case C.TB_OPERATION_ARCHERDB_GET_STATUS:
		return unsafe.Sizeof(types.StatusResponse{})
	default:
		return 1 // Return 1 for unknown ops to avoid divide by zero
	}
}

//export onGoPacketCompletion
func onGoPacketCompletion(
	_context C.uintptr_t,
	packet *C.tb_packet_t,
	timestamp C.uint64_t,
	result_ptr C.tb_result_bytes_t,
	result_len C.uint32_t,
) {
	_ = _context
	_ = timestamp

	// Get the request from the packet user data.
	req := (*request)(unsafe.Pointer(packet.user_data))
	var reply []uint8 = nil
	if result_len > 0 && result_ptr != nil {
		op := C.TB_OPERATION(packet.operation)

		// Make sure the completion handler is giving us valid data.
		resultSize := C.uint32_t(getResultSize(op))
		if result_len%resultSize != 0 {
			panic("invalid result_len:  misaligned for the event")
		}

		// GeoClient operations with variable-size responses skip the asymmetric check
		if op != C.TB_OPERATION_INSERT_EVENTS &&
			op != C.TB_OPERATION_UPSERT_EVENTS &&
			op != C.TB_OPERATION_DELETE_ENTITIES &&
			op != C.TB_OPERATION_QUERY_UUID &&
			op != C.TB_OPERATION_QUERY_LATEST &&
			op != C.TB_OPERATION_QUERY_RADIUS &&
			op != C.TB_OPERATION_QUERY_POLYGON &&
			op != C.TB_OPERATION_ARCHERDB_PING &&
			op != C.TB_OPERATION_ARCHERDB_GET_STATUS {
			// Make sure the amount of results at least matches the amount of requests.
			count := packet.data_size / C.uint32_t(getEventSize(op))
			if count*resultSize < result_len {
				panic("invalid result_len: implied multiple results per event")
			}
		}

		// Copy the result data into a new buffer.
		reply = make([]uint8, result_len)
		C.memcpy(unsafe.Pointer(&reply[0]), unsafe.Pointer(result_ptr), C.size_t(result_len))
	}

	// Signal to the goroutine which owns this request that it's ready.
	req.ready <- reply
}
