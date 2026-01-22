// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

// S2 Golden Vector Generator
//
// This program generates golden test vectors for validating ArcherDB's S2 implementation
// against the Google S2 reference library (Go version).
//
// Usage:
//
//	go build && ./s2_golden_gen
//
// Output files are written to ../../testdata/s2/
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/golang/geo/s1"
	"github.com/golang/geo/s2"
)

const (
	outputDir = "../../testdata/s2"
)

func main() {
	// Ensure output directory exists
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create output directory: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("S2 Golden Vector Generator")
	fmt.Println("==========================")
	fmt.Println()

	// Generate each type of golden vector file
	if err := generateCellIdVectors(); err != nil {
		fmt.Fprintf(os.Stderr, "Error generating cell ID vectors: %v\n", err)
		os.Exit(1)
	}

	if err := generateHierarchyVectors(); err != nil {
		fmt.Fprintf(os.Stderr, "Error generating hierarchy vectors: %v\n", err)
		os.Exit(1)
	}

	if err := generateNeighborVectors(); err != nil {
		fmt.Fprintf(os.Stderr, "Error generating neighbor vectors: %v\n", err)
		os.Exit(1)
	}

	if err := generateCoveringVectors(); err != nil {
		fmt.Fprintf(os.Stderr, "Error generating covering vectors: %v\n", err)
		os.Exit(1)
	}

	fmt.Println()
	fmt.Println("Done! Golden vectors written to", outputDir)
}

// generateCellIdVectors creates cell_id_golden.tsv with lat/lon to cell ID mappings.
// Covers:
// - Grid of coordinates (every 10 degrees lat/lon)
// - All 6 faces explicitly tested
// - Poles (lat=89.999999, -89.999999)
// - Antimeridian (lon=179.999999, -179.999999)
// - All S2 levels (0-30) for subset of coordinates
func generateCellIdVectors() error {
	path := filepath.Join(outputDir, "cell_id_golden.tsv")
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	// Header
	fmt.Fprintln(f, "lat_nano\tlon_nano\tlevel\tcell_id_hex")

	count := 0

	// 1. Grid of coordinates at level 30 (finest)
	// Every 10 degrees for comprehensive coverage
	for lat := -90; lat <= 90; lat += 10 {
		for lon := -180; lon <= 180; lon += 10 {
			latNano := int64(lat) * 1_000_000_000
			lonNano := int64(lon) * 1_000_000_000
			cellID := latLonToCellID(latNano, lonNano, 30)
			fmt.Fprintf(f, "%d\t%d\t%d\t0x%016x\n", latNano, lonNano, 30, cellID)
			count++
		}
	}

	// 2. All levels (0-30) for key coordinates
	keyCoords := [][2]int64{
		{0, 0},                               // Origin
		{37_774900000, -122_419400000},       // San Francisco
		{51_507400000, -127800000},           // London
		{35_689500000, 139_691700000},        // Tokyo
		{-33_868800000, 151_209300000},       // Sydney
		{55_751200000, 37_618400000},         // Moscow
		{-22_906800000, -43_172900000},       // Rio de Janeiro
		{48_856600000, 2_352200000},          // Paris
		{40_712800000, -74_006000000},        // New York
		{1_352100000, 103_819800000},         // Singapore
	}
	for _, coord := range keyCoords {
		for level := 0; level <= 30; level++ {
			cellID := latLonToCellID(coord[0], coord[1], level)
			fmt.Fprintf(f, "%d\t%d\t%d\t0x%016x\n", coord[0], coord[1], level, cellID)
			count++
		}
	}

	// 3. Poles (near-poles to avoid singularity issues)
	poleCoords := [][2]int64{
		{89_999999000, 0},                 // Near north pole
		{-89_999999000, 0},                // Near south pole
		{89_999999000, 90_000_000_000},    // North pole, lon 90
		{89_999999000, -90_000_000_000},   // North pole, lon -90
		{89_999999000, 180_000_000_000},   // North pole, lon 180
		{-89_999999000, 90_000_000_000},   // South pole, lon 90
		{-89_999999000, -90_000_000_000},  // South pole, lon -90
		{-89_999999000, 180_000_000_000},  // South pole, lon 180
	}
	for _, coord := range poleCoords {
		for level := 0; level <= 30; level += 5 {
			cellID := latLonToCellID(coord[0], coord[1], level)
			fmt.Fprintf(f, "%d\t%d\t%d\t0x%016x\n", coord[0], coord[1], level, cellID)
			count++
		}
	}

	// 4. Antimeridian tests
	antimeridianCoords := [][2]int64{
		{0, 179_999999000},    // Just before +180
		{0, -179_999999000},   // Just before -180
		{45_000_000_000, 179_999999000},
		{45_000_000_000, -179_999999000},
		{-45_000_000_000, 179_999999000},
		{-45_000_000_000, -179_999999000},
	}
	for _, coord := range antimeridianCoords {
		for level := 0; level <= 30; level += 5 {
			cellID := latLonToCellID(coord[0], coord[1], level)
			fmt.Fprintf(f, "%d\t%d\t%d\t0x%016x\n", coord[0], coord[1], level, cellID)
			count++
		}
	}

	// 5. Face coverage - coordinates that explicitly land on each of the 6 faces
	// Face 0: +X (lon ~0, lat ~0)
	// Face 1: +Y (lon ~90, lat ~0)
	// Face 2: +Z (north pole)
	// Face 3: -X (lon ~180, lat ~0)
	// Face 4: -Y (lon ~-90, lat ~0)
	// Face 5: -Z (south pole)
	faceCoords := [][2]int64{
		{0, 0},                    // Face 0
		{0, 90_000_000_000},       // Face 1
		{89_000_000_000, 0},       // Face 2
		{0, 180_000_000_000},      // Face 3
		{0, -90_000_000_000},      // Face 4
		{-89_000_000_000, 0},      // Face 5
	}
	for _, coord := range faceCoords {
		for level := 0; level <= 30; level++ {
			cellID := latLonToCellID(coord[0], coord[1], level)
			fmt.Fprintf(f, "%d\t%d\t%d\t0x%016x\n", coord[0], coord[1], level, cellID)
			count++
		}
	}

	// 6. Dense grid at level 30 for high-resolution validation
	// Every 1 degree near the equator
	for lat := -10; lat <= 10; lat++ {
		for lon := -10; lon <= 10; lon++ {
			latNano := int64(lat) * 1_000_000_000
			lonNano := int64(lon) * 1_000_000_000
			cellID := latLonToCellID(latNano, lonNano, 30)
			fmt.Fprintf(f, "%d\t%d\t%d\t0x%016x\n", latNano, lonNano, 30, cellID)
			count++
		}
	}

	fmt.Printf("Generated %d cell ID vectors -> %s\n", count, path)
	return nil
}

// generateHierarchyVectors creates hierarchy_golden.tsv with parent/children relationships.
func generateHierarchyVectors() error {
	path := filepath.Join(outputDir, "hierarchy_golden.tsv")
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	// Header
	fmt.Fprintln(f, "cell_id_hex\tparent_hex\tchild0_hex\tchild1_hex\tchild2_hex\tchild3_hex")

	count := 0

	// Test coordinates at various levels
	coords := [][2]int64{
		{0, 0},
		{37_774900000, -122_419400000},
		{51_507400000, -127800000},
		{35_689500000, 139_691700000},
		{-33_868800000, 151_209300000},
		{89_000_000_000, 0},
		{-89_000_000_000, 0},
		{0, 90_000_000_000},
		{0, -90_000_000_000},
		{0, 180_000_000_000},
	}

	// For each coordinate, test hierarchy at each level
	for _, coord := range coords {
		for level := 1; level <= 29; level++ {
			cellID := latLonToCellID(coord[0], coord[1], level)
			cell := s2.CellID(cellID)

			// Get parent (one level up)
			parent := cell.Parent(cell.Level() - 1)

			// Get children (if not at max level)
			var children [4]s2.CellID
			if level < 30 {
				for i := 0; i < 4; i++ {
					children[i] = cell.Children()[i]
				}
			}

			fmt.Fprintf(f, "0x%016x\t0x%016x\t0x%016x\t0x%016x\t0x%016x\t0x%016x\n",
				uint64(cell), uint64(parent),
				uint64(children[0]), uint64(children[1]),
				uint64(children[2]), uint64(children[3]))
			count++
		}
	}

	// Additional tests: level 0 cells and their children
	for face := 0; face < 6; face++ {
		cell := s2.CellIDFromFace(face)
		children := cell.Children()
		// Level 0 has no parent, use 0 as placeholder
		fmt.Fprintf(f, "0x%016x\t0x%016x\t0x%016x\t0x%016x\t0x%016x\t0x%016x\n",
			uint64(cell), uint64(0),
			uint64(children[0]), uint64(children[1]),
			uint64(children[2]), uint64(children[3]))
		count++
	}

	fmt.Printf("Generated %d hierarchy vectors -> %s\n", count, path)
	return nil
}

// generateNeighborVectors creates neighbors_golden.tsv with edge neighbor relationships.
func generateNeighborVectors() error {
	path := filepath.Join(outputDir, "neighbors_golden.tsv")
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	// Header
	fmt.Fprintln(f, "cell_id_hex\tn0_hex\tn1_hex\tn2_hex\tn3_hex")

	count := 0

	// Test coordinates
	coords := [][2]int64{
		{0, 0},
		{37_774900000, -122_419400000},
		{51_507400000, -127800000},
		{35_689500000, 139_691700000},
		{-33_868800000, 151_209300000},
		{0, 90_000_000_000},
		{0, -90_000_000_000},
		{45_000_000_000, 179_000_000_000},
		{-45_000_000_000, -179_000_000_000},
	}

	// Test at various levels
	levels := []int{5, 10, 15, 20, 25, 30}

	for _, coord := range coords {
		for _, level := range levels {
			cellID := latLonToCellID(coord[0], coord[1], level)
			cell := s2.CellID(cellID)

			// Get edge neighbors
			neighbors := cell.EdgeNeighbors()

			fmt.Fprintf(f, "0x%016x\t0x%016x\t0x%016x\t0x%016x\t0x%016x\n",
				uint64(cell),
				uint64(neighbors[0]), uint64(neighbors[1]),
				uint64(neighbors[2]), uint64(neighbors[3]))
			count++
		}
	}

	// Additional tests at face boundaries
	for face := 0; face < 6; face++ {
		for level := 1; level <= 10; level++ {
			// Cell at center of face
			cell := s2.CellIDFromFace(face).ChildBeginAtLevel(level)
			neighbors := cell.EdgeNeighbors()

			fmt.Fprintf(f, "0x%016x\t0x%016x\t0x%016x\t0x%016x\t0x%016x\n",
				uint64(cell),
				uint64(neighbors[0]), uint64(neighbors[1]),
				uint64(neighbors[2]), uint64(neighbors[3]))
			count++
		}
	}

	fmt.Printf("Generated %d neighbor vectors -> %s\n", count, path)
	return nil
}

// generateCoveringVectors creates covering_golden.tsv with region covering test cases.
func generateCoveringVectors() error {
	path := filepath.Join(outputDir, "covering_golden.tsv")
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	// Header
	fmt.Fprintln(f, "lat_nano\tlon_nano\tradius_m\tmin_level\tmax_level\tmax_cells\tcell_ids_comma_sep")

	count := 0

	// Test configurations
	type coveringTest struct {
		latNano  int64
		lonNano  int64
		radiusM  float64
		minLevel int
		maxLevel int
		maxCells int
	}

	tests := []coveringTest{
		// Small radii (building-scale)
		{37_774900000, -122_419400000, 100, 20, 30, 8},
		{37_774900000, -122_419400000, 50, 25, 30, 8},
		{51_507400000, -127800000, 100, 20, 30, 8},

		// Medium radii (neighborhood-scale)
		{37_774900000, -122_419400000, 1000, 15, 25, 16},
		{35_689500000, 139_691700000, 1000, 15, 25, 16},
		{-33_868800000, 151_209300000, 1000, 15, 25, 16},

		// Large radii (city-scale)
		{37_774900000, -122_419400000, 10000, 10, 20, 32},
		{0, 0, 10000, 10, 20, 32},
		{51_507400000, -127800000, 10000, 10, 20, 32},

		// Very large radii (country-scale)
		{0, 0, 100000, 5, 15, 64},
		{37_774900000, -122_419400000, 100000, 5, 15, 64},

		// Edge cases near poles
		{89_000_000_000, 0, 1000, 15, 25, 16},
		{-89_000_000_000, 0, 1000, 15, 25, 16},

		// Edge cases near antimeridian
		{0, 179_000_000_000, 1000, 15, 25, 16},
		{0, -179_000_000_000, 1000, 15, 25, 16},
	}

	for _, t := range tests {
		// Create cap from lat/lon and radius
		lat := float64(t.latNano) / 1_000_000_000.0
		lon := float64(t.lonNano) / 1_000_000_000.0
		point := s2.PointFromLatLng(s2.LatLngFromDegrees(lat, lon))

		// Convert radius in meters to angle (using Earth radius ~6371km)
		angleRad := t.radiusM / 6371000.0
		cap := s2.CapFromCenterAngle(point, s1.Angle(angleRad))

		// Create coverer
		coverer := s2.RegionCoverer{
			MinLevel: t.minLevel,
			MaxLevel: t.maxLevel,
			MaxCells: t.maxCells,
		}

		// Get covering
		covering := coverer.Covering(cap)

		// Convert to hex strings
		var cellStrs []string
		for _, cell := range covering {
			cellStrs = append(cellStrs, fmt.Sprintf("0x%016x", uint64(cell)))
		}

		fmt.Fprintf(f, "%d\t%d\t%.0f\t%d\t%d\t%d\t%s\n",
			t.latNano, t.lonNano, t.radiusM,
			t.minLevel, t.maxLevel, t.maxCells,
			strings.Join(cellStrs, ","))
		count++
	}

	fmt.Printf("Generated %d covering vectors -> %s\n", count, path)
	return nil
}

// latLonToCellID converts lat/lon in nanodegrees to S2 cell ID at given level.
func latLonToCellID(latNano, lonNano int64, level int) uint64 {
	lat := float64(latNano) / 1_000_000_000.0
	lon := float64(lonNano) / 1_000_000_000.0
	ll := s2.LatLngFromDegrees(lat, lon)
	cellID := s2.CellIDFromLatLng(ll).Parent(level)
	return uint64(cellID)
}
