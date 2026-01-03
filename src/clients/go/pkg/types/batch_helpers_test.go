package types

import (
	"reflect"
	"testing"
)

func TestSplitAccountBatch_Basic(t *testing.T) {
	accounts := []Account{
		{ID: Uint128{1, 0}},
		{ID: Uint128{2, 0}},
		{ID: Uint128{3, 0}},
		{ID: Uint128{4, 0}},
		{ID: Uint128{5, 0}},
		{ID: Uint128{6, 0}},
		{ID: Uint128{7, 0}},
		{ID: Uint128{8, 0}},
		{ID: Uint128{9, 0}},
		{ID: Uint128{10, 0}},
	}

	// Split into chunks of 3
	chunks := SplitAccountBatch(accounts, 3)

	if len(chunks) != 4 {
		t.Errorf("SplitAccountBatch() returned %d chunks, want 4", len(chunks))
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

func TestSplitAccountBatch_ExactDivision(t *testing.T) {
	accounts := []Account{
		{ID: Uint128{1, 0}},
		{ID: Uint128{2, 0}},
		{ID: Uint128{3, 0}},
		{ID: Uint128{4, 0}},
		{ID: Uint128{5, 0}},
		{ID: Uint128{6, 0}},
	}

	// Split into chunks of 2 (exact division)
	chunks := SplitAccountBatch(accounts, 2)

	if len(chunks) != 3 {
		t.Errorf("SplitAccountBatch() returned %d chunks, want 3", len(chunks))
	}
	for i, chunk := range chunks {
		if len(chunk) != 2 {
			t.Errorf("Chunk %d has %d items, want 2", i, len(chunk))
		}
	}
}

func TestSplitAccountBatch_EmptySlice(t *testing.T) {
	accounts := []Account{}

	chunks := SplitAccountBatch(accounts, 3)

	if chunks != nil {
		t.Errorf("SplitAccountBatch() = %v, want nil", chunks)
	}
}

func TestSplitAccountBatch_SingleChunk(t *testing.T) {
	accounts := []Account{
		{ID: Uint128{1, 0}},
		{ID: Uint128{2, 0}},
		{ID: Uint128{3, 0}},
	}

	// Chunk size larger than slice
	chunks := SplitAccountBatch(accounts, 10)

	if len(chunks) != 1 {
		t.Errorf("SplitAccountBatch() returned %d chunks, want 1", len(chunks))
	}
	if len(chunks[0]) != 3 {
		t.Errorf("First chunk has %d items, want 3", len(chunks[0]))
	}
}

func TestSplitAccountBatch_ChunkSizeOne(t *testing.T) {
	accounts := []Account{
		{ID: Uint128{1, 0}},
		{ID: Uint128{2, 0}},
		{ID: Uint128{3, 0}},
	}

	chunks := SplitAccountBatch(accounts, 1)

	if len(chunks) != 3 {
		t.Errorf("SplitAccountBatch() returned %d chunks, want 3", len(chunks))
	}
	for i, chunk := range chunks {
		if len(chunk) != 1 {
			t.Errorf("Chunk %d has %d items, want 1", i, len(chunk))
		}
	}
}

func TestSplitAccountBatch_ZeroChunkSize_Panics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("SplitAccountBatch() should panic for chunkSize <= 0")
		}
	}()

	accounts := []Account{{ID: Uint128{1, 0}}}
	SplitAccountBatch(accounts, 0)
}

func TestSplitAccountBatch_NegativeChunkSize_Panics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("SplitAccountBatch() should panic for negative chunkSize")
		}
	}()

	accounts := []Account{{ID: Uint128{1, 0}}}
	SplitAccountBatch(accounts, -1)
}

func TestSplitTransferBatch(t *testing.T) {
	transfers := []Transfer{
		{ID: Uint128{1, 0}},
		{ID: Uint128{2, 0}},
		{ID: Uint128{3, 0}},
		{ID: Uint128{4, 0}},
	}

	chunks := SplitTransferBatch(transfers, 2)

	if len(chunks) != 2 {
		t.Errorf("SplitTransferBatch() returned %d chunks, want 2", len(chunks))
	}
	if len(chunks[0]) != 2 {
		t.Errorf("First chunk has %d items, want 2", len(chunks[0]))
	}
	if len(chunks[1]) != 2 {
		t.Errorf("Second chunk has %d items, want 2", len(chunks[1]))
	}
}

func TestSplitTransferBatch_Empty(t *testing.T) {
	transfers := []Transfer{}
	chunks := SplitTransferBatch(transfers, 3)
	if chunks != nil {
		t.Errorf("SplitTransferBatch() = %v, want nil", chunks)
	}
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
