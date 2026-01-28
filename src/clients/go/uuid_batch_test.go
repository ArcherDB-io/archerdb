package archerdb

import (
	"encoding/binary"
	"testing"
	"unsafe"

	"github.com/archerdb/archerdb-go/pkg/types"
)

func TestParseQueryUUIDBatchResponse(t *testing.T) {
	const headerSize = 16
	foundCount := uint32(2)
	notFoundCount := uint32(1)
	eventSize := int(unsafe.Sizeof(types.GeoEvent{}))

	indicesSize := int(notFoundCount) * 2
	indicesEnd := headerSize + indicesSize
	eventsOffset := indicesEnd
	if rem := eventsOffset % 16; rem != 0 {
		eventsOffset += 16 - rem
	}

	totalSize := eventsOffset + int(foundCount)*eventSize
	reply := make([]byte, totalSize)

	binary.LittleEndian.PutUint32(reply[0:4], foundCount)
	binary.LittleEndian.PutUint32(reply[4:8], notFoundCount)
	binary.LittleEndian.PutUint16(reply[16:18], 1)

	events := []types.GeoEvent{
		{
			EntityID:  types.BytesToUint128([16]byte{1}),
			LatNano:   10,
			LonNano:   20,
			Timestamp: 100,
		},
		{
			EntityID:  types.BytesToUint128([16]byte{2}),
			LatNano:   30,
			LonNano:   40,
			Timestamp: 200,
		},
	}
	eventBytes := unsafe.Slice((*byte)(unsafe.Pointer(&events[0])), int(foundCount)*eventSize)
	copy(reply[eventsOffset:], eventBytes)

	result, err := parseQueryUUIDBatchResponse(reply)
	if err != nil {
		t.Fatalf("parseQueryUUIDBatchResponse failed: %v", err)
	}

	if result.FoundCount != foundCount {
		t.Fatalf("FoundCount = %d, want %d", result.FoundCount, foundCount)
	}
	if result.NotFoundCount != notFoundCount {
		t.Fatalf("NotFoundCount = %d, want %d", result.NotFoundCount, notFoundCount)
	}
	if len(result.NotFoundIndices) != int(notFoundCount) || result.NotFoundIndices[0] != 1 {
		t.Fatalf("NotFoundIndices = %v, want [1]", result.NotFoundIndices)
	}
	if len(result.Events) != int(foundCount) {
		t.Fatalf("Events length = %d, want %d", len(result.Events), foundCount)
	}
	if result.Events[0].Timestamp != 100 || result.Events[1].Timestamp != 200 {
		t.Fatalf("Unexpected event timestamps: %+v", result.Events)
	}
}
