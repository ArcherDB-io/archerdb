package types

import (
	"reflect"
	"testing"
)

func TestSplitGeoEventBatch_Basic(t *testing.T) {
	events := []GeoEvent{
		{EntityID: Uint128{1, 0}},
		{EntityID: Uint128{2, 0}},
		{EntityID: Uint128{3, 0}},
		{EntityID: Uint128{4, 0}},
		{EntityID: Uint128{5, 0}},
		{EntityID: Uint128{6, 0}},
		{EntityID: Uint128{7, 0}},
		{EntityID: Uint128{8, 0}},
		{EntityID: Uint128{9, 0}},
		{EntityID: Uint128{10, 0}},
	}

	// Split into chunks of 3
	chunks := SplitGeoEventBatch(events, 3)

	if len(chunks) != 4 {
		t.Errorf("SplitGeoEventBatch() returned %d chunks, want 4", len(chunks))
	}
	if len(chunks[0]) != 3 {
		t.Errorf("First chunk has %d items, want 3", len(chunks[0]))
	}
	if len(chunks[1]) != 3 {
		t.Errorf("Second chunk has %d items, want 3", len(chunks[1]))
	}
	if len(chunks[2]) != 3 {
		t.Errorf("Third chunk has %d items, want 3", len(chunks[2]))
	}
	if len(chunks[3]) != 1 {
		t.Errorf("Fourth chunk has %d items, want 1", len(chunks[3]))
	}
}

func TestSplitGeoEventBatch_ExactDivision(t *testing.T) {
	events := []GeoEvent{
		{EntityID: Uint128{1, 0}},
		{EntityID: Uint128{2, 0}},
		{EntityID: Uint128{3, 0}},
		{EntityID: Uint128{4, 0}},
		{EntityID: Uint128{5, 0}},
		{EntityID: Uint128{6, 0}},
	}

	// Split into chunks of 2 (exact division)
	chunks := SplitGeoEventBatch(events, 2)

	if len(chunks) != 3 {
		t.Errorf("SplitGeoEventBatch() returned %d chunks, want 3", len(chunks))
	}
	for i, chunk := range chunks {
		if len(chunk) != 2 {
			t.Errorf("Chunk %d has %d items, want 2", i, len(chunk))
		}
	}
}

func TestSplitGeoEventBatch_EmptySlice(t *testing.T) {
	events := []GeoEvent{}

	chunks := SplitGeoEventBatch(events, 3)

	if chunks != nil {
		t.Errorf("SplitGeoEventBatch() = %v, want nil", chunks)
	}
}

func TestSplitGeoEventBatch_SingleChunk(t *testing.T) {
	events := []GeoEvent{
		{EntityID: Uint128{1, 0}},
		{EntityID: Uint128{2, 0}},
		{EntityID: Uint128{3, 0}},
	}

	// Chunk size larger than slice
	chunks := SplitGeoEventBatch(events, 10)

	if len(chunks) != 1 {
		t.Errorf("SplitGeoEventBatch() returned %d chunks, want 1", len(chunks))
	}
	if len(chunks[0]) != 3 {
		t.Errorf("First chunk has %d items, want 3", len(chunks[0]))
	}
}

func TestSplitGeoEventBatch_ChunkSizeOne(t *testing.T) {
	events := []GeoEvent{
		{EntityID: Uint128{1, 0}},
		{EntityID: Uint128{2, 0}},
		{EntityID: Uint128{3, 0}},
	}

	chunks := SplitGeoEventBatch(events, 1)

	if len(chunks) != 3 {
		t.Errorf("SplitGeoEventBatch() returned %d chunks, want 3", len(chunks))
	}
	for i, chunk := range chunks {
		if len(chunk) != 1 {
			t.Errorf("Chunk %d has %d items, want 1", i, len(chunk))
		}
	}
}

func TestSplitGeoEventBatch_ZeroChunkSize_Panics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("SplitGeoEventBatch() should panic for chunkSize <= 0")
		}
	}()

	events := []GeoEvent{{EntityID: Uint128{1, 0}}}
	SplitGeoEventBatch(events, 0)
}

func TestSplitGeoEventBatch_NegativeChunkSize_Panics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("SplitGeoEventBatch() should panic for negative chunkSize")
		}
	}()

	events := []GeoEvent{{EntityID: Uint128{1, 0}}}
	SplitGeoEventBatch(events, -1)
}

func TestSplitUint128Batch(t *testing.T) {
	ids := []Uint128{
		{1, 0},
		{2, 0},
		{3, 0},
	}

	chunks := SplitUint128Batch(ids, 2)

	if len(chunks) != 2 {
		t.Errorf("SplitUint128Batch() returned %d chunks, want 2", len(chunks))
	}
	if len(chunks[0]) != 2 {
		t.Errorf("First chunk has %d items, want 2", len(chunks[0]))
	}
	if len(chunks[1]) != 1 {
		t.Errorf("Second chunk has %d items, want 1", len(chunks[1]))
	}
}

func TestSplitUint128Batch_PreservesOrder(t *testing.T) {
	ids := []Uint128{
		{1, 0},
		{2, 0},
		{3, 0},
		{4, 0},
		{5, 0},
	}

	chunks := SplitUint128Batch(ids, 2)

	expected := [][]Uint128{
		{{1, 0}, {2, 0}},
		{{3, 0}, {4, 0}},
		{{5, 0}},
	}

	if !reflect.DeepEqual(chunks, expected) {
		t.Errorf("SplitUint128Batch() = %v, want %v", chunks, expected)
	}
}
