// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package archerdb

import (
	"testing"
	"time"

	"github.com/archerdb/archerdb-go/pkg/types"
)

func TestSubmitInsertBatchesOffsetsIndices(t *testing.T) {
	events := []types.GeoEvent{
		{EntityID: types.ToUint128(1)},
		{EntityID: types.ToUint128(2)},
		{EntityID: types.ToUint128(3)},
	}

	errors, err := submitInsertBatches(events, 2, func(_ []types.GeoEvent) ([]types.InsertGeoEventsError, error) {
		return []types.InsertGeoEventsError{
			{Index: 0, Result: types.InsertResultInvalidCoordinates},
		}, nil
	})
	if err != nil {
		t.Fatalf("submitInsertBatches returned error: %v", err)
	}

	if len(errors) != 2 {
		t.Fatalf("expected 2 errors, got %d", len(errors))
	}
	if errors[0].Index != 0 {
		t.Fatalf("expected first error index 0, got %d", errors[0].Index)
	}
	if errors[1].Index != 2 {
		t.Fatalf("expected second error index 2, got %d", errors[1].Index)
	}
}

func TestSubmitInsertBatchesRetriesFailedBatchOnly(t *testing.T) {
	client := &geoClient{
		retryConfig: RetryConfig{
			Enabled:      true,
			MaxRetries:   1,
			BaseBackoff:  0,
			MaxBackoff:   0,
			TotalTimeout: time.Second,
		},
	}

	events := []types.GeoEvent{
		{EntityID: types.ToUint128(1)},
		{EntityID: types.ToUint128(2)},
		{EntityID: types.ToUint128(3)},
		{EntityID: types.ToUint128(4)},
	}

	attempts := map[string]int{}
	failKey := types.ToUint128(3).String()

	errors, err := submitInsertBatches(events, 2, func(chunk []types.GeoEvent) ([]types.InsertGeoEventsError, error) {
		key := chunk[0].EntityID.String()
		return client.withRetry(func() ([]types.InsertGeoEventsError, error) {
			attempts[key]++
			if key == failKey && attempts[key] == 1 {
				return nil, OperationTimeoutError{Msg: "timeout"}
			}
			return []types.InsertGeoEventsError{}, nil
		})
	})
	if err != nil {
		t.Fatalf("submitInsertBatches returned error: %v", err)
	}
	if len(errors) != 0 {
		t.Fatalf("expected no errors, got %d", len(errors))
	}

	if attempts[types.ToUint128(1).String()] != 1 {
		t.Fatalf("expected first batch attempts 1, got %d", attempts[types.ToUint128(1).String()])
	}
	if attempts[failKey] != 2 {
		t.Fatalf("expected failing batch attempts 2, got %d", attempts[failKey])
	}
}
