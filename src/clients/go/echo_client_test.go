// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package archerdb

import (
	"bytes"
	"testing"
	"unsafe"

	"github.com/archerdb/archerdb-go/pkg/types"
)

func TestEchoClient(t *testing.T) {
	client, err := NewGeoClientEcho(GeoClientConfig{
		ClusterID: types.Uint128{},
		Addresses: []string{"3000"},
	})
	if err != nil {
		t.Fatalf("NewGeoClientEcho failed: %v", err)
	}
	defer client.Close()

	geo, ok := client.(*geoClient)
	if !ok {
		t.Fatalf("expected *geoClient, got %T", client)
	}

	event := types.GeoEvent{
		EntityID:    types.BytesToUint128([16]byte{1}),
		LatNano:     37_774_900_000,
		LonNano:     -122_419_400_000,
		GroupID:     1,
		TTLSeconds:  86_400,
		AccuracyMM:  5_000,
		HeadingCdeg: 0,
		Flags:       types.GeoEventFlagNone,
	}
	types.PrepareGeoEvent(&event)

	eventSize := int(unsafe.Sizeof(types.GeoEvent{}))
	reply, err := geo.doGeoRequest(
		types.GeoOperationInsertEvents,
		1,
		unsafe.Sizeof(types.GeoEvent{}),
		unsafe.Pointer(&event),
	)
	if err != nil {
		t.Fatalf("doGeoRequest failed: %v", err)
	}
	if len(reply) != eventSize {
		t.Fatalf("unexpected reply size: got %d, want %d", len(reply), eventSize)
	}

	eventBytes := unsafe.Slice((*byte)(unsafe.Pointer(&event)), eventSize)
	if !bytes.Equal(reply, eventBytes) {
		t.Fatal("echoed bytes do not match request")
	}
}
