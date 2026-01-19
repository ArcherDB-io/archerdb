// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package types

import (
	"sync"
)

// ============================================================================
// Conflict Resolution Types (v2.2)
// Active-Active Replication Support
// ============================================================================

// ConflictResolutionPolicy defines how write conflicts are resolved.
type ConflictResolutionPolicy uint8

const (
	// ConflictResolutionLastWriterWins uses highest timestamp (default).
	ConflictResolutionLastWriterWins ConflictResolutionPolicy = 0
	// ConflictResolutionPrimaryWins gives primary region precedence.
	ConflictResolutionPrimaryWins ConflictResolutionPolicy = 1
	// ConflictResolutionCustomHook uses application-provided resolver.
	ConflictResolutionCustomHook ConflictResolutionPolicy = 2
)

// String returns the string representation of the policy.
func (p ConflictResolutionPolicy) String() string {
	switch p {
	case ConflictResolutionLastWriterWins:
		return "last_writer_wins"
	case ConflictResolutionPrimaryWins:
		return "primary_wins"
	case ConflictResolutionCustomHook:
		return "custom_hook"
	default:
		return "unknown"
	}
}

// VectorClock tracks causality in distributed systems.
type VectorClock struct {
	mu      sync.RWMutex
	entries map[string]uint64
}

// NewVectorClock creates an empty vector clock.
func NewVectorClock() *VectorClock {
	return &VectorClock{
		entries: make(map[string]uint64),
	}
}

// Get returns the timestamp for a region.
func (vc *VectorClock) Get(regionID string) uint64 {
	vc.mu.RLock()
	defer vc.mu.RUnlock()
	return vc.entries[regionID]
}

// Set sets the timestamp for a region.
func (vc *VectorClock) Set(regionID string, timestamp uint64) {
	vc.mu.Lock()
	defer vc.mu.Unlock()
	vc.entries[regionID] = timestamp
}

// Increment increments the timestamp for a region.
func (vc *VectorClock) Increment(regionID string) uint64 {
	vc.mu.Lock()
	defer vc.mu.Unlock()
	vc.entries[regionID]++
	return vc.entries[regionID]
}

// Merge merges another vector clock into this one (takes max of each entry).
func (vc *VectorClock) Merge(other *VectorClock) {
	other.mu.RLock()
	defer other.mu.RUnlock()
	vc.mu.Lock()
	defer vc.mu.Unlock()

	for regionID, timestamp := range other.entries {
		if timestamp > vc.entries[regionID] {
			vc.entries[regionID] = timestamp
		}
	}
}

// Clone creates a deep copy of the vector clock.
func (vc *VectorClock) Clone() *VectorClock {
	vc.mu.RLock()
	defer vc.mu.RUnlock()

	clone := NewVectorClock()
	for k, v := range vc.entries {
		clone.entries[k] = v
	}
	return clone
}

// Entries returns a copy of all entries.
func (vc *VectorClock) Entries() map[string]uint64 {
	vc.mu.RLock()
	defer vc.mu.RUnlock()

	result := make(map[string]uint64, len(vc.entries))
	for k, v := range vc.entries {
		result[k] = v
	}
	return result
}

// Compare compares two vector clocks.
// Returns: -1 if vc < other, 0 if concurrent, 1 if vc > other
func (vc *VectorClock) Compare(other *VectorClock) int {
	vc.mu.RLock()
	other.mu.RLock()
	defer vc.mu.RUnlock()
	defer other.mu.RUnlock()

	vcGreater := false
	otherGreater := false

	// Check entries in this clock
	for regionID, ts := range vc.entries {
		otherTs := other.entries[regionID]
		if ts > otherTs {
			vcGreater = true
		}
		if ts < otherTs {
			otherGreater = true
		}
	}

	// Check entries only in other clock
	for regionID, ts := range other.entries {
		if _, exists := vc.entries[regionID]; !exists && ts > 0 {
			otherGreater = true
		}
	}

	if vcGreater && !otherGreater {
		return 1
	}
	if otherGreater && !vcGreater {
		return -1
	}
	return 0 // Concurrent
}

// HappenedBefore returns true if this clock happened before other.
func (vc *VectorClock) HappenedBefore(other *VectorClock) bool {
	return vc.Compare(other) < 0
}

// IsConcurrent returns true if the clocks are concurrent.
func (vc *VectorClock) IsConcurrent(other *VectorClock) bool {
	return vc.Compare(other) == 0
}

// ConflictInfo contains information about a detected conflict.
type ConflictInfo struct {
	// EntityID is the entity with the conflict.
	EntityID Uint128
	// LocalClock is the vector clock of the local write.
	LocalClock *VectorClock
	// RemoteClock is the vector clock of the remote write.
	RemoteClock *VectorClock
	// LocalRegion is where the local write originated.
	LocalRegion string
	// RemoteRegion is where the remote write originated.
	RemoteRegion string
	// LocalTimestamp is the local write timestamp (nanoseconds).
	LocalTimestamp uint64
	// RemoteTimestamp is the remote write timestamp (nanoseconds).
	RemoteTimestamp uint64
}

// ConflictResolution contains the result of conflict resolution.
type ConflictResolution struct {
	// WinningRegion is the region whose write won.
	WinningRegion string
	// Policy is the resolution policy used.
	Policy ConflictResolutionPolicy
	// MergedClock is the resulting merged vector clock.
	MergedClock *VectorClock
	// LocalWins indicates if the local write won.
	LocalWins bool
}

// ConflictStats contains statistics about conflict resolution.
type ConflictStats struct {
	// TotalConflicts is the total number detected.
	TotalConflicts uint64
	// LastWriterWinsCount resolved by last-writer-wins.
	LastWriterWinsCount uint64
	// PrimaryWinsCount resolved by primary-wins.
	PrimaryWinsCount uint64
	// CustomHookCount resolved by custom hook.
	CustomHookCount uint64
	// LastConflictTimestamp is the timestamp of the last conflict (nanoseconds).
	LastConflictTimestamp uint64
}

// ConflictAuditEntry is an entry in the conflict audit log.
type ConflictAuditEntry struct {
	// AuditID is the unique ID for this entry.
	AuditID uint64
	// EntityID is the entity with the conflict.
	EntityID Uint128
	// DetectedTimestamp is when the conflict was detected (nanoseconds).
	DetectedTimestamp uint64
	// WinningRegion is the winning region ID.
	WinningRegion string
	// LosingRegion is the losing region ID.
	LosingRegion string
	// Policy is the resolution policy used.
	Policy ConflictResolutionPolicy
	// WinningData is the serialized winning write (for auditing).
	WinningData []byte
	// LosingData is the serialized losing write (for auditing).
	LosingData []byte
}

// ConflictResolver handles conflict detection and resolution.
type ConflictResolver struct {
	policy        ConflictResolutionPolicy
	primaryRegion string
	customHook    func(ConflictInfo) ConflictResolution
	mu            sync.RWMutex
	stats         ConflictStats
}

// NewConflictResolver creates a new resolver with the given policy.
func NewConflictResolver(policy ConflictResolutionPolicy, primaryRegion string) *ConflictResolver {
	return &ConflictResolver{
		policy:        policy,
		primaryRegion: primaryRegion,
	}
}

// SetCustomHook sets the custom resolution hook.
func (cr *ConflictResolver) SetCustomHook(hook func(ConflictInfo) ConflictResolution) {
	cr.mu.Lock()
	defer cr.mu.Unlock()
	cr.customHook = hook
}

// DetectConflict checks if two writes are concurrent (conflicting).
func (cr *ConflictResolver) DetectConflict(localClock, remoteClock *VectorClock) bool {
	return localClock.IsConcurrent(remoteClock)
}

// Resolve resolves a conflict using the configured policy.
func (cr *ConflictResolver) Resolve(info ConflictInfo) ConflictResolution {
	cr.mu.Lock()
	defer cr.mu.Unlock()

	cr.stats.TotalConflicts++
	cr.stats.LastConflictTimestamp = info.LocalTimestamp

	var result ConflictResolution
	result.MergedClock = info.LocalClock.Clone()
	result.MergedClock.Merge(info.RemoteClock)

	switch cr.policy {
	case ConflictResolutionLastWriterWins:
		cr.stats.LastWriterWinsCount++
		result.Policy = ConflictResolutionLastWriterWins
		if info.LocalTimestamp >= info.RemoteTimestamp {
			result.WinningRegion = info.LocalRegion
			result.LocalWins = true
		} else {
			result.WinningRegion = info.RemoteRegion
			result.LocalWins = false
		}

	case ConflictResolutionPrimaryWins:
		cr.stats.PrimaryWinsCount++
		result.Policy = ConflictResolutionPrimaryWins
		if info.LocalRegion == cr.primaryRegion {
			result.WinningRegion = info.LocalRegion
			result.LocalWins = true
		} else if info.RemoteRegion == cr.primaryRegion {
			result.WinningRegion = info.RemoteRegion
			result.LocalWins = false
		} else {
			// Neither is primary, fall back to last-writer-wins
			if info.LocalTimestamp >= info.RemoteTimestamp {
				result.WinningRegion = info.LocalRegion
				result.LocalWins = true
			} else {
				result.WinningRegion = info.RemoteRegion
				result.LocalWins = false
			}
		}

	case ConflictResolutionCustomHook:
		cr.stats.CustomHookCount++
		result.Policy = ConflictResolutionCustomHook
		if cr.customHook != nil {
			return cr.customHook(info)
		}
		// Fall back to last-writer-wins if no hook
		if info.LocalTimestamp >= info.RemoteTimestamp {
			result.WinningRegion = info.LocalRegion
			result.LocalWins = true
		} else {
			result.WinningRegion = info.RemoteRegion
			result.LocalWins = false
		}
	}

	return result
}

// GetStats returns current conflict statistics.
func (cr *ConflictResolver) GetStats() ConflictStats {
	cr.mu.RLock()
	defer cr.mu.RUnlock()
	return cr.stats
}
