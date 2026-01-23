// Package types provides the core data structures for the ArcherDB Go SDK.
//
// This package contains type definitions for:
//   - Uint128/Int128: 128-bit integer types for IDs and coordinates
//   - GeoEvent: The core geospatial event record
//   - Query filters and results
//   - Topology and shard routing types
//
// # Coordinate Units
//
// ArcherDB uses precise integer units to avoid floating-point errors:
//   - Latitude/Longitude: nanodegrees (10^-9 degrees)
//   - Altitude/Radius/Accuracy: millimeters
//   - Velocity: millimeters per second
//   - Heading: centidegrees (0.01 degrees)
//   - Timestamp: nanoseconds since Unix epoch
//
// Helper functions convert between user-friendly units and internal representation:
//
//	lat := types.DegreesToNano(37.7749)  // Convert degrees to nanodegrees
//	alt := types.MetersToMM(100.5)       // Convert meters to millimeters
//
// # ID Generation
//
// Use ID() to generate sortable UUIDs (ULID format):
//
//	entityID := types.ID()  // Generates a monotonically increasing UUID
package types

/*
#include "../native/arch_client.h"
*/
import "C"
import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/big"
	"sync"
	"time"
	"unsafe"
)

// Uint128 represents an unsigned 128-bit integer.
//
// Used for entity IDs, cluster IDs, and other 128-bit identifiers.
// Stored in little-endian byte order for wire compatibility.
//
// Create instances using:
//   - ToUint128(uint64): From a 64-bit value
//   - ID(): Generate a sortable UUID
//   - HexStringToUint128("abc123"): From hex string
//   - BytesToUint128([16]byte): From raw bytes
//
// Example:
//
//	id := types.ToUint128(12345)
//	uuid := types.ID()  // Sortable UUID
type Uint128 C.arch_uint128_t

// Int128 represents a signed 128-bit integer.
//
// Used internally for signed coordinate calculations.
type Int128 C.arch_int128_t

// Bytes returns the Uint128 as a 16-byte array in little-endian order.
//
// The byte representation is compatible with ArcherDB's wire format.
func (value Uint128) Bytes() [16]byte {
	return *(*[16]byte)(unsafe.Pointer(&value))
}

func swapEndian(bytes []byte) {
	for i, j := 0, len(bytes)-1; i < j; i, j = i+1, j-1 {
		bytes[i], bytes[j] = bytes[j], bytes[i]
	}
}

// String returns the hex string representation of the Uint128.
//
// Leading zeros are trimmed for readability. The returned string
// is suitable for logging and display.
//
// Example:
//
//	id := types.ToUint128(255)
//	fmt.Println(id.String())  // "ff"
func (value Uint128) String() string {
	bytes := value.Bytes()

	// Convert little-endian Uint128 number to big-endian string.
	swapEndian(bytes[:])
	s := hex.EncodeToString(bytes[:16])

	// Prettier to drop preceding zeros so you get "0" instead of "0000000000000000".
	lastNonZero := 0
	for s[lastNonZero] == '0' && lastNonZero < len(s)-1 {
		lastNonZero++
	}
	return s[lastNonZero:]
}

// BigInt converts the Uint128 to a math/big.Int for arbitrary precision arithmetic.
//
// Use this for operations that need arbitrary precision or for interoperability
// with other libraries that use big.Int.
func (value Uint128) BigInt() big.Int {
	// big.Int uses bytes in big-endian but Uint128 stores bytes in little endian, so reverse it.
	bytes := value.Bytes()
	swapEndian(bytes[:])

	ret := big.Int{}
	ret.SetBytes(bytes[:])
	return ret
}

// BytesToUint128 converts a 16-byte array to Uint128.
//
// The bytes should be in little-endian order (ArcherDB wire format).
func BytesToUint128(value [16]byte) Uint128 {
	return *(*Uint128)(unsafe.Pointer(&value[0]))
}

// HexStringToUint128 parses a hex-encoded string into a Uint128.
//
// The string should not have a "0x" prefix and must be at most 32 hex digits.
// Leading zeros in the string are optional.
//
// Example:
//
//	id, err := types.HexStringToUint128("abc123")
//	id, err := types.HexStringToUint128("0000000000000000abc123")  // Same result
func HexStringToUint128(value string) (Uint128, error) {
	if len(value) > 32 {
		return Uint128{}, fmt.Errorf("Uint128 hex string must not be more than 32 bytes.")
	}
	if len(value)%2 == 1 {
		value = "0" + value
	}

	bytes := [16]byte{}
	nonZeroLen, err := hex.Decode(bytes[:], []byte(value))
	if err != nil {
		return Uint128{}, err
	}

	// Convert big-endian string to little endian number
	for i := 0; i < nonZeroLen/2; i += 1 {
		j := nonZeroLen - 1 - i
		bytes[i], bytes[j] = bytes[j], bytes[i]
	}

	return BytesToUint128(bytes), nil
}

// BigIntToUint128 converts a math/big.Int to a Uint128.
//
// Panics if the value is negative. Values larger than 2^128-1 are truncated.
func BigIntToUint128(value big.Int) Uint128 {
	if value.Sign() < 0 {
		panic("cannot convert negative big.Int to Uint128")
	}

	// big.Int bytes are big-endian so convert them to little-endian for Uint128 bytes.
	bytes := value.Bytes()
	swapEndian(bytes[:])

	// Only cast slice to bytes when there's enough.
	if len(bytes) >= 16 {
		return BytesToUint128(*(*[16]byte)(bytes))
	}

	var zeroPadded [16]byte
	copy(zeroPadded[:], bytes)
	return BytesToUint128(zeroPadded)
}

// ToUint128 converts a uint64 to a Uint128.
//
// The upper 64 bits are set to zero.
//
// Example:
//
//	clusterID := types.ToUint128(0)  // Cluster ID 0
//	groupID := types.ToUint128(12345)
func ToUint128(value uint64) Uint128 {
	values := [2]uint64{value, 0}
	return *(*Uint128)(unsafe.Pointer(&values[0]))
}

var idLastTimestamp int64
var idLastRandom [10]byte
var idMutex sync.Mutex

// ID generates a Universally Unique and Sortable Identifier (ULID).
//
// The generated IDs have these properties:
//   - Globally unique (128-bit with 80 bits of randomness per millisecond)
//   - Monotonically increasing within a process
//   - Lexicographically sortable when encoded as bytes
//   - Contains embedded timestamp (millisecond precision)
//
// ID() is safe for concurrent use by multiple goroutines. IDs generated
// concurrently are guaranteed to be monotonically increasing in call order.
//
// Use ID() for entity IDs and correlation IDs:
//
//	event := types.GeoEvent{
//	    EntityID:      types.ID(),
//	    CorrelationID: types.ID(),
//	    // ...
//	}
//
// See https://github.com/ulid/spec for the ULID specification.
func ID() Uint128 {
	timestamp := time.Now().UnixMilli()

	// Lock the mutex for global id variables.
	// Then ensure lastTimestamp is monotonically increasing & lastRandom changes each millisecond
	idMutex.Lock()
	if timestamp <= idLastTimestamp {
		timestamp = idLastTimestamp
	} else {
		idLastTimestamp = timestamp
		_, err := rand.Read(idLastRandom[:])
		if err != nil {
			idMutex.Unlock()
			panic("crypto.rand failed to provide random bytes")
		}
	}

	// Read out a uint80 from lastRandom as a uint64 and uint16.
	randomLo := binary.LittleEndian.Uint64(idLastRandom[:8])
	randomHi := binary.LittleEndian.Uint16(idLastRandom[8:])

	// Increment the random bits as a uint80 together, checking for overflow.
	// Go defines unsigned arithmetic to wrap around on overflow by default so check for zero.
	randomLo += 1
	if randomLo == 0 {
		randomHi += 1
		if randomHi == 0 {
			idMutex.Unlock()
			panic("random bits overflow on monotonic increment")
		}
	}

	// Write incremented uint80 back to lastRandom and stop mutating global id variables.
	binary.LittleEndian.PutUint64(idLastRandom[:8], randomLo)
	binary.LittleEndian.PutUint16(idLastRandom[8:], randomHi)
	idMutex.Unlock()

	// Create Uint128 from new timestamp and random.
	var id [16]byte
	binary.LittleEndian.PutUint64(id[:8], randomLo)
	binary.LittleEndian.PutUint16(id[8:], randomHi)
	binary.LittleEndian.PutUint16(id[10:], (uint16)(timestamp))     // timestamp lo
	binary.LittleEndian.PutUint32(id[12:], (uint32)(timestamp>>16)) // timestamp hi
	return BytesToUint128(id)
}
