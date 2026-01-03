package types

// SplitAccountBatch splits a slice of Account into smaller chunks for retry scenarios.
//
// When a large batch times out, the SDK cannot determine which events succeeded
// vs failed. Use this helper to split the batch into smaller chunks and retry
// each chunk individually. The server's idempotency guarantees ensure that
// any already-committed events will not be duplicated.
//
// Parameters:
//   - accounts: Slice of accounts to split
//   - chunkSize: Maximum size of each chunk (must be > 0)
//
// Returns:
//   - A slice of slices, each containing at most chunkSize items
//   - Returns nil for empty input
//
// Example:
//
//	// Original batch timed out
//	accounts := generateLargeAccountList()
//
//	// Split into smaller batches for retry
//	chunks := types.SplitAccountBatch(accounts, 500)
//
//	for _, chunk := range chunks {
//	    results, err := client.CreateAccounts(chunk)
//	    if err != nil {
//	        // Handle retry with even smaller chunks
//	        smallerChunks := types.SplitAccountBatch(chunk, 100)
//	        // ...
//	    }
//	}
func SplitAccountBatch(accounts []Account, chunkSize int) [][]Account {
	if chunkSize <= 0 {
		panic("chunkSize must be greater than 0")
	}

	if len(accounts) == 0 {
		return nil
	}

	numChunks := (len(accounts) + chunkSize - 1) / chunkSize
	chunks := make([][]Account, 0, numChunks)

	for i := 0; i < len(accounts); i += chunkSize {
		end := i + chunkSize
		if end > len(accounts) {
			end = len(accounts)
		}
		chunks = append(chunks, accounts[i:end])
	}

	return chunks
}

// SplitTransferBatch splits a slice of Transfer into smaller chunks.
// See SplitAccountBatch for full documentation.
func SplitTransferBatch(transfers []Transfer, chunkSize int) [][]Transfer {
	if chunkSize <= 0 {
		panic("chunkSize must be greater than 0")
	}

	if len(transfers) == 0 {
		return nil
	}

	numChunks := (len(transfers) + chunkSize - 1) / chunkSize
	chunks := make([][]Transfer, 0, numChunks)

	for i := 0; i < len(transfers); i += chunkSize {
		end := i + chunkSize
		if end > len(transfers) {
			end = len(transfers)
		}
		chunks = append(chunks, transfers[i:end])
	}

	return chunks
}

// SplitUint128Batch splits a slice of Uint128 into smaller chunks.
// This is useful for splitting batches of IDs (e.g., for batch lookups).
// See SplitAccountBatch for full documentation.
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
