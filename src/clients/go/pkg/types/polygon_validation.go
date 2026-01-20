// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-present ArcherDB
//
// Polygon self-intersection validation (per add-polygon-validation spec).

package types

import (
	"errors"
	"fmt"
	"math"
)

const eps = 1e-10

// PolygonValidationError indicates a polygon self-intersection.
type PolygonValidationError struct {
	// Segment1Index is the index of the first intersecting segment (0-based)
	Segment1Index int
	// Segment2Index is the index of the second intersecting segment (0-based)
	Segment2Index int
	// IntersectionPoint is the approximate intersection point [lat, lon] in degrees
	IntersectionPoint [2]float64
	// Message is the human-readable error message
	Message string
	// RepairSuggestions contains suggestions for fixing the self-intersection
	RepairSuggestions []string
}

func (e *PolygonValidationError) Error() string {
	return e.Message
}

// GetRepairSuggestions returns suggestions for fixing the self-intersection.
func (e *PolygonValidationError) GetRepairSuggestions() []string {
	return e.RepairSuggestions
}

// IntersectionInfo contains information about a detected self-intersection.
type IntersectionInfo struct {
	// Segment1Index is the index of the first intersecting segment
	Segment1Index int
	// Segment2Index is the index of the second intersecting segment
	Segment2Index int
	// IntersectionPoint is the approximate intersection point [lat, lon] in degrees
	IntersectionPoint [2]float64
}

// SegmentsIntersect checks if two line segments intersect.
//
// Uses the cross product method with proper handling of collinear cases.
// Points are represented as [lat, lon] in degrees.
func SegmentsIntersect(p1, p2, p3, p4 [2]float64) bool {
	crossProduct := func(o, a, b [2]float64) float64 {
		return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
	}

	onSegment := func(p, q, r [2]float64) bool {
		return q[0] >= math.Min(p[0], r[0]) && q[0] <= math.Max(p[0], r[0]) &&
			q[1] >= math.Min(p[1], r[1]) && q[1] <= math.Max(p[1], r[1])
	}

	d1 := crossProduct(p3, p4, p1)
	d2 := crossProduct(p3, p4, p2)
	d3 := crossProduct(p1, p2, p3)
	d4 := crossProduct(p1, p2, p4)

	// General case: segments cross
	if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
		((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
		return true
	}

	// Collinear cases
	if math.Abs(d1) < eps && onSegment(p3, p1, p4) {
		return true
	}
	if math.Abs(d2) < eps && onSegment(p3, p2, p4) {
		return true
	}
	if math.Abs(d3) < eps && onSegment(p1, p3, p2) {
		return true
	}
	if math.Abs(d4) < eps && onSegment(p1, p4, p2) {
		return true
	}

	return false
}

// ValidatePolygonNoSelfIntersection validates that a polygon has no self-intersections.
//
// Uses an O(n^2) algorithm suitable for polygons with reasonable vertex counts.
// If raiseOnError is true, returns an error on the first intersection found.
// Otherwise, returns all intersections found.
func ValidatePolygonNoSelfIntersection(vertices [][2]float64, raiseOnError bool) ([]IntersectionInfo, error) {
	var intersections []IntersectionInfo

	// A triangle cannot self-intersect (3 vertices = 3 edges, need at least 4 for crossing)
	if len(vertices) < 4 {
		return intersections, nil
	}

	n := len(vertices)

	// Check all pairs of non-adjacent edges
	for i := 0; i < n; i++ {
		p1 := vertices[i]
		p2 := vertices[(i+1)%n]

		// Start from i+2 to skip adjacent edges (they share a vertex)
		for j := i + 2; j < n; j++ {
			// Skip if edges share a vertex (adjacent edges)
			if j == (i+n-1)%n {
				continue
			}

			p3 := vertices[j]
			p4 := vertices[(j+1)%n]

			if SegmentsIntersect(p1, p2, p3, p4) {
				// Calculate approximate intersection point for error message
				ix := (p1[0] + p2[0] + p3[0] + p4[0]) / 4.0
				iy := (p1[1] + p2[1] + p3[1] + p4[1]) / 4.0
				intersection := [2]float64{ix, iy}

				if raiseOnError {
					// Generate repair suggestions
					suggestions := make([]string, 0, 4)
					v1Idx := (i + 1) % n
					v2Idx := (j + 1) % n

					suggestions = append(suggestions,
						fmt.Sprintf("Try removing vertex %d at (%.6f, %.6f)", v1Idx, vertices[v1Idx][0], vertices[v1Idx][1]))
					suggestions = append(suggestions,
						fmt.Sprintf("Try removing vertex %d at (%.6f, %.6f)", v2Idx, vertices[v2Idx][0], vertices[v2Idx][1]))

					// Detect bow-tie pattern
					if j-i == 2 {
						suggestions = append(suggestions,
							fmt.Sprintf("Bow-tie pattern detected: try swapping vertices %d and %d", i+1, j))
					}

					suggestions = append(suggestions,
						"Ensure vertices are ordered consistently (clockwise or counter-clockwise)")

					return nil, &PolygonValidationError{
						Segment1Index:     i,
						Segment2Index:     j,
						IntersectionPoint: intersection,
						Message: fmt.Sprintf("polygon self-intersects: edge %d-%d crosses edge %d-%d near (%.6f, %.6f)",
							i, (i+1)%n, j, (j+1)%n, ix, iy),
						RepairSuggestions: suggestions,
					}
				}

				intersections = append(intersections, IntersectionInfo{
					Segment1Index:     i,
					Segment2Index:     j,
					IntersectionPoint: intersection,
				})
			}
		}
	}

	return intersections, nil
}

// ValidatePolygonQuery validates a QueryPolygonFilter for self-intersections.
func ValidatePolygonQuery(filter QueryPolygonFilter) error {
	if len(filter.Vertices) == 0 {
		return errors.New("polygon has no vertices")
	}

	vertices := make([][2]float64, len(filter.Vertices))
	for i, v := range filter.Vertices {
		vertices[i] = [2]float64{
			NanoToDegrees(v.LatNano),
			NanoToDegrees(v.LonNano),
		}
	}

	_, err := ValidatePolygonNoSelfIntersection(vertices, true)
	return err
}
