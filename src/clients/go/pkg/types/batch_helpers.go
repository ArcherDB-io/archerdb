package types

// SplitGeoEventBatch splits a slice of GeoEvent into smaller chunks for retry scenarios.
//
// When a large batch times out, the SDK cannot determine which events succeeded
// vs failed. Use this helper to split the batch into smaller chunks and retry
// each chunk individually. The server's idempotency guarantees ensure that
// any already-committed events will not be duplicated.
//
// Parameters:
//   - events: Slice of GeoEvents to split
//   - chunkSize: Maximum size of each chunk (must be > 0)
//
// Returns:
//   - A slice of slices, each containing at most chunkSize items
//   - Returns nil for empty input
//
// Example:
//
//	// Original batch timed out
//	events := generateLargeEventList()
//
//	// Split into smaller batches for retry
//	chunks := types.SplitGeoEventBatch(events, 500)
//
//	for _, chunk := range chunks {
//	    results, err := client.InsertEvents(chunk)
//	    if err != nil {
//	        // Handle retry with even smaller chunks
//	        smallerChunks := types.SplitGeoEventBatch(chunk, 100)
//	        // ...
//	    }
//	}
func SplitGeoEventBatch(events []GeoEvent, chunkSize int) [][]GeoEvent {
	if chunkSize <= 0 {
		panic("chunkSize must be greater than 0")
	}

	if len(events) == 0 {
		return nil
	}

	numChunks := (len(events) + chunkSize - 1) / chunkSize
	chunks := make([][]GeoEvent, 0, numChunks)

	for i := 0; i < len(events); i += chunkSize {
		end := i + chunkSize
		if end > len(events) {
			end = len(events)
		}
		chunks = append(chunks, events[i:end])
	}

	return chunks
}

// SplitUint128Batch splits a slice of Uint128 into smaller chunks.
// This is useful for splitting batches of entity IDs (e.g., for batch lookups or deletes).
// See SplitGeoEventBatch for full documentation.
func SplitUint128Batch(ids []Uint128, chunkSize int) [][]Uint128 {
	if chunkSize <= 0 {
		panic("chunkSize must be greater than 0")
	}

	if len(ids) == 0 {
		return nil
	}

	numChunks := (len(ids) + chunkSize - 1) / chunkSize
	chunks := make([][]Uint128, 0, numChunks)

	for i := 0; i < len(ids); i += chunkSize {
		end := i + chunkSize
		if end > len(ids) {
			end = len(ids)
		}
		chunks = append(chunks, ids[i:end])
	}

	return chunks
}
