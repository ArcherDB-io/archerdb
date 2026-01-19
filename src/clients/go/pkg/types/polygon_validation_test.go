// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-present ArcherDB
//
// Tests for polygon self-intersection validation (add-polygon-validation spec).

package types

import (
	"math"
	"testing"
)

func TestValidTriangle(t *testing.T) {
	// Triangle cannot self-intersect (too few edges)
	triangle := [][2]float64{
		{0.0, 0.0},
		{1.0, 0.0},
		{0.5, 1.0},
	}
	result, err := ValidatePolygonNoSelfIntersection(triangle, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("expected no intersections, got %d", len(result))
	}
}

func TestValidSquare(t *testing.T) {
	// Simple square has no self-intersections
	square := [][2]float64{
		{0.0, 0.0},
		{1.0, 0.0},
		{1.0, 1.0},
		{0.0, 1.0},
	}
	result, err := ValidatePolygonNoSelfIntersection(square, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("expected no intersections, got %d", len(result))
	}
}

func TestValidConvexPentagon(t *testing.T) {
	// Convex pentagon has no self-intersections
	pentagon := make([][2]float64, 5)
	for i := 0; i < 5; i++ {
		angle := 2.0 * math.Pi * float64(i) / 5.0
		pentagon[i] = [2]float64{math.Cos(angle), math.Sin(angle)}
	}
	result, err := ValidatePolygonNoSelfIntersection(pentagon, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("expected no intersections, got %d", len(result))
	}
}

func TestBowtiePolygonIntersects(t *testing.T) {
	// Bow-tie (figure-8) polygon has a self-intersection
	bowtie := [][2]float64{
		{0.0, 0.0},
		{1.0, 1.0},
		{1.0, 0.0},
		{0.0, 1.0},
	}
	result, err := ValidatePolygonNoSelfIntersection(bowtie, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) == 0 {
		t.Error("expected intersections in bow-tie polygon")
	}
}

func TestBowtieRaisesError(t *testing.T) {
	// Bow-tie polygon returns error when raiseOnError=true
	bowtie := [][2]float64{
		{0.0, 0.0},
		{1.0, 1.0},
		{1.0, 0.0},
		{0.0, 1.0},
	}
	_, err := ValidatePolygonNoSelfIntersection(bowtie, true)
	if err == nil {
		t.Fatal("expected error for bow-tie polygon")
	}

	validationErr, ok := err.(*PolygonValidationError)
	if !ok {
		t.Fatalf("expected PolygonValidationError, got %T", err)
	}

	if validationErr.Segment1Index < 0 || validationErr.Segment1Index >= 4 {
		t.Errorf("unexpected segment1 index: %d", validationErr.Segment1Index)
	}
	if validationErr.Segment2Index < 0 || validationErr.Segment2Index >= 4 {
		t.Errorf("unexpected segment2 index: %d", validationErr.Segment2Index)
	}
}

func TestValidConcavePolygon(t *testing.T) {
	// Concave (non-convex) polygon without self-intersections (L-shape)
	lShape := [][2]float64{
		{0.0, 0.0},
		{2.0, 0.0},
		{2.0, 1.0},
		{1.0, 1.0},
		{1.0, 2.0},
		{0.0, 2.0},
	}
	result, err := ValidatePolygonNoSelfIntersection(lShape, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("expected no intersections, got %d", len(result))
	}
}

func TestStarPolygonIntersects(t *testing.T) {
	// 5-pointed star (drawn without lifting pen) self-intersects
	star := make([][2]float64, 5)
	for i := 0; i < 5; i++ {
		angle := math.Pi/2.0 + float64(i)*4.0*math.Pi/5.0
		star[i] = [2]float64{math.Cos(angle), math.Sin(angle)}
	}
	result, err := ValidatePolygonNoSelfIntersection(star, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) == 0 {
		t.Error("expected intersections in 5-pointed star")
	}
}

func TestSegmentsIntersectBasic(t *testing.T) {
	// Clearly crossing segments
	if !SegmentsIntersect(
		[2]float64{0.0, 0.0}, [2]float64{1.0, 1.0}, // Diagonal
		[2]float64{0.0, 1.0}, [2]float64{1.0, 0.0}, // Opposite diagonal
	) {
		t.Error("crossing segments should intersect")
	}

	// Parallel segments (no intersection)
	if SegmentsIntersect(
		[2]float64{0.0, 0.0}, [2]float64{1.0, 0.0}, // Horizontal
		[2]float64{0.0, 1.0}, [2]float64{1.0, 1.0}, // Parallel horizontal
	) {
		t.Error("parallel segments should not intersect")
	}

	// T-junction (endpoint touches)
	if !SegmentsIntersect(
		[2]float64{0.0, 0.5}, [2]float64{1.0, 0.5}, // Horizontal
		[2]float64{0.5, 0.0}, [2]float64{0.5, 0.5}, // Vertical ending at intersection
	) {
		t.Error("T-junction segments should intersect")
	}
}

func TestPolygonValidationErrorAttributes(t *testing.T) {
	err := &PolygonValidationError{
		Segment1Index:     1,
		Segment2Index:     3,
		IntersectionPoint: [2]float64{0.5, 0.5},
		Message:           "Test error",
	}

	if err.Segment1Index != 1 {
		t.Errorf("expected segment1Index 1, got %d", err.Segment1Index)
	}
	if err.Segment2Index != 3 {
		t.Errorf("expected segment2Index 3, got %d", err.Segment2Index)
	}
	if err.IntersectionPoint[0] != 0.5 || err.IntersectionPoint[1] != 0.5 {
		t.Errorf("unexpected intersection point: %v", err.IntersectionPoint)
	}
	if err.Error() != "Test error" {
		t.Errorf("unexpected error message: %s", err.Error())
	}
}

func TestEmptyOrSmallPolygon(t *testing.T) {
	// Empty
	result, err := ValidatePolygonNoSelfIntersection([][2]float64{}, false)
	if err != nil || len(result) != 0 {
		t.Error("empty polygon should return no intersections")
	}

	// Single point
	result, err = ValidatePolygonNoSelfIntersection([][2]float64{{0, 0}}, false)
	if err != nil || len(result) != 0 {
		t.Error("single point should return no intersections")
	}

	// Two points (line)
	result, err = ValidatePolygonNoSelfIntersection([][2]float64{{0, 0}, {1, 1}}, false)
	if err != nil || len(result) != 0 {
		t.Error("two points should return no intersections")
	}

	// Three points (triangle - minimum valid polygon)
	result, err = ValidatePolygonNoSelfIntersection([][2]float64{{0, 0}, {1, 0}, {0, 1}}, false)
	if err != nil || len(result) != 0 {
		t.Error("triangle should return no intersections")
	}
}

func TestValidatePolygonQuery(t *testing.T) {
	// Valid square query
	validQuery, _ := NewPolygonQuery([][]float64{
		{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 1.0},
	}, 100)
	if err := ValidatePolygonQuery(validQuery); err != nil {
		t.Errorf("valid query should not error: %v", err)
	}

	// Invalid bow-tie query
	invalidQuery, _ := NewPolygonQuery([][]float64{
		{0.0, 0.0}, {1.0, 1.0}, {1.0, 0.0}, {0.0, 1.0},
	}, 100)
	if err := ValidatePolygonQuery(invalidQuery); err == nil {
		t.Error("bow-tie query should error")
	}
}
