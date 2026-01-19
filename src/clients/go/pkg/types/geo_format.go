// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package types

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// ============================================================================
// GeoJSON/WKT Protocol Support (per add-geojson-wkt-protocol spec)
// ============================================================================

// GeoFormatError represents an error parsing GeoJSON or WKT.
type GeoFormatError struct {
	Message string
}

func (e *GeoFormatError) Error() string {
	return e.Message
}

// GeoFormat represents the format for geographic data output.
type GeoFormat uint8

const (
	// GeoFormatNative uses native nanodegree format.
	GeoFormatNative GeoFormat = 0
	// GeoFormatGeoJSON uses GeoJSON format.
	GeoFormatGeoJSON GeoFormat = 1
	// GeoFormatWKT uses Well-Known Text format.
	GeoFormatWKT GeoFormat = 2
)

// GeoJSONPoint represents a GeoJSON Point geometry.
type GeoJSONPoint struct {
	Type        string    `json:"type"`
	Coordinates []float64 `json:"coordinates"`
}

// GeoJSONPolygon represents a GeoJSON Polygon geometry.
type GeoJSONPolygon struct {
	Type        string        `json:"type"`
	Coordinates [][][]float64 `json:"coordinates"`
}

// ParseGeoJSONPoint parses a GeoJSON Point to nanodegree coordinates.
// Returns (lat_nano, lon_nano).
func ParseGeoJSONPoint(geojson string) (int64, int64, error) {
	var point GeoJSONPoint
	if err := json.Unmarshal([]byte(geojson), &point); err != nil {
		return 0, 0, &GeoFormatError{Message: fmt.Sprintf("invalid JSON: %v", err)}
	}

	return ParseGeoJSONPointObj(&point)
}

// ParseGeoJSONPointObj parses a GeoJSON Point object to nanodegree coordinates.
func ParseGeoJSONPointObj(point *GeoJSONPoint) (int64, int64, error) {
	if point.Type != "Point" {
		return 0, 0, &GeoFormatError{Message: fmt.Sprintf("expected type 'Point', got '%s'", point.Type)}
	}

	if len(point.Coordinates) < 2 {
		return 0, 0, &GeoFormatError{Message: "Point must have [lon, lat] coordinates"}
	}

	lon := point.Coordinates[0]
	lat := point.Coordinates[1]

	if err := validateCoordinates(lat, lon); err != nil {
		return 0, 0, err
	}

	return DegreesToNano(lat), DegreesToNano(lon), nil
}

// ParseGeoJSONPolygon parses a GeoJSON Polygon to nanodegree coordinates.
// Returns (exterior, holes).
func ParseGeoJSONPolygon(geojson string) ([][2]int64, [][][2]int64, error) {
	var polygon GeoJSONPolygon
	if err := json.Unmarshal([]byte(geojson), &polygon); err != nil {
		return nil, nil, &GeoFormatError{Message: fmt.Sprintf("invalid JSON: %v", err)}
	}

	return ParseGeoJSONPolygonObj(&polygon)
}

// ParseGeoJSONPolygonObj parses a GeoJSON Polygon object to nanodegree coordinates.
func ParseGeoJSONPolygonObj(polygon *GeoJSONPolygon) ([][2]int64, [][][2]int64, error) {
	if polygon.Type != "Polygon" {
		return nil, nil, &GeoFormatError{Message: fmt.Sprintf("expected type 'Polygon', got '%s'", polygon.Type)}
	}

	if len(polygon.Coordinates) < 1 {
		return nil, nil, &GeoFormatError{Message: "Polygon must have at least one ring"}
	}

	parseRing := func(ring [][]float64) ([][2]int64, error) {
		if len(ring) < 3 {
			return nil, &GeoFormatError{Message: fmt.Sprintf("ring must have at least 3 vertices, got %d", len(ring))}
		}

		result := make([][2]int64, len(ring))
		for i, point := range ring {
			if len(point) < 2 {
				return nil, &GeoFormatError{Message: fmt.Sprintf("point %d must have [lon, lat]", i)}
			}
			lon := point[0]
			lat := point[1]
			if err := validateCoordinates(lat, lon); err != nil {
				return nil, err
			}
			result[i] = [2]int64{DegreesToNano(lat), DegreesToNano(lon)}
		}
		return result, nil
	}

	exterior, err := parseRing(polygon.Coordinates[0])
	if err != nil {
		return nil, nil, err
	}

	var holes [][][2]int64
	for i := 1; i < len(polygon.Coordinates); i++ {
		hole, err := parseRing(polygon.Coordinates[i])
		if err != nil {
			return nil, nil, err
		}
		holes = append(holes, hole)
	}

	return exterior, holes, nil
}

// ParseWKTPoint parses a WKT POINT to nanodegree coordinates.
// Returns (lat_nano, lon_nano).
func ParseWKTPoint(wkt string) (int64, int64, error) {
	wkt = strings.TrimSpace(wkt)
	upper := strings.ToUpper(wkt)

	if !strings.HasPrefix(upper, "POINT") {
		return 0, 0, &GeoFormatError{Message: "expected POINT"}
	}

	openParen := strings.Index(wkt, "(")
	closeParen := strings.LastIndex(wkt, ")")
	if openParen == -1 || closeParen == -1 || openParen >= closeParen {
		return 0, 0, &GeoFormatError{Message: "invalid WKT POINT: missing parentheses"}
	}

	content := strings.TrimSpace(wkt[openParen+1 : closeParen])
	parts := regexp.MustCompile(`\s+`).Split(content, -1)
	if len(parts) < 2 {
		return 0, 0, &GeoFormatError{Message: "POINT must have lon lat coordinates"}
	}

	lon, err := strconv.ParseFloat(parts[0], 64)
	if err != nil {
		return 0, 0, &GeoFormatError{Message: fmt.Sprintf("invalid longitude: %s", parts[0])}
	}

	lat, err := strconv.ParseFloat(parts[1], 64)
	if err != nil {
		return 0, 0, &GeoFormatError{Message: fmt.Sprintf("invalid latitude: %s", parts[1])}
	}

	if err := validateCoordinates(lat, lon); err != nil {
		return 0, 0, err
	}

	return DegreesToNano(lat), DegreesToNano(lon), nil
}

// ParseWKTPolygon parses a WKT POLYGON to nanodegree coordinates.
// Returns (exterior, holes).
func ParseWKTPolygon(wkt string) ([][2]int64, [][][2]int64, error) {
	wkt = strings.TrimSpace(wkt)
	upper := strings.ToUpper(wkt)

	if !strings.HasPrefix(upper, "POLYGON") {
		return nil, nil, &GeoFormatError{Message: "expected POLYGON"}
	}

	outerStart := strings.Index(wkt, "(")
	outerEnd := strings.LastIndex(wkt, ")")
	if outerStart == -1 || outerEnd == -1 || outerStart >= outerEnd {
		return nil, nil, &GeoFormatError{Message: "invalid WKT POLYGON: missing parentheses"}
	}

	content := wkt[outerStart+1 : outerEnd]

	// Find matching parentheses for each ring
	var rings []string
	depth := 0
	ringStart := 0
	for i := 0; i < len(content); i++ {
		switch content[i] {
		case '(':
			if depth == 0 {
				ringStart = i
			}
			depth++
		case ')':
			depth--
			if depth == 0 {
				rings = append(rings, content[ringStart:i+1])
			}
		}
	}

	if len(rings) == 0 {
		return nil, nil, &GeoFormatError{Message: "POLYGON must have at least one ring"}
	}

	parseRing := func(ring string) ([][2]int64, error) {
		ring = strings.TrimSpace(ring)
		if !strings.HasPrefix(ring, "(") || !strings.HasSuffix(ring, ")") {
			return nil, &GeoFormatError{Message: "ring must be enclosed in parentheses"}
		}

		ringContent := ring[1 : len(ring)-1]
		pointStrs := strings.Split(ringContent, ",")

		if len(pointStrs) < 3 {
			return nil, &GeoFormatError{Message: fmt.Sprintf("ring must have at least 3 vertices, got %d", len(pointStrs))}
		}

		result := make([][2]int64, len(pointStrs))
		for i, pointStr := range pointStrs {
			parts := regexp.MustCompile(`\s+`).Split(strings.TrimSpace(pointStr), -1)
			if len(parts) < 2 {
				return nil, &GeoFormatError{Message: fmt.Sprintf("invalid point at index %d", i)}
			}

			lon, err := strconv.ParseFloat(parts[0], 64)
			if err != nil {
				return nil, &GeoFormatError{Message: fmt.Sprintf("invalid longitude at point %d", i)}
			}

			lat, err := strconv.ParseFloat(parts[1], 64)
			if err != nil {
				return nil, &GeoFormatError{Message: fmt.Sprintf("invalid latitude at point %d", i)}
			}

			if err := validateCoordinates(lat, lon); err != nil {
				return nil, err
			}

			result[i] = [2]int64{DegreesToNano(lat), DegreesToNano(lon)}
		}
		return result, nil
	}

	exterior, err := parseRing(rings[0])
	if err != nil {
		return nil, nil, err
	}

	var holes [][][2]int64
	for i := 1; i < len(rings); i++ {
		hole, err := parseRing(rings[i])
		if err != nil {
			return nil, nil, err
		}
		holes = append(holes, hole)
	}

	return exterior, holes, nil
}

// ToGeoJSONPoint converts nanodegree coordinates to a GeoJSON Point.
func ToGeoJSONPoint(latNano, lonNano int64) *GeoJSONPoint {
	return &GeoJSONPoint{
		Type:        "Point",
		Coordinates: []float64{NanoToDegrees(lonNano), NanoToDegrees(latNano)},
	}
}

// ToGeoJSONPolygon converts nanodegree coordinates to a GeoJSON Polygon.
func ToGeoJSONPolygon(exterior [][2]int64, holes [][][2]int64) *GeoJSONPolygon {
	ringToCoords := func(ring [][2]int64) [][]float64 {
		result := make([][]float64, len(ring))
		for i, point := range ring {
			result[i] = []float64{NanoToDegrees(point[1]), NanoToDegrees(point[0])}
		}
		return result
	}

	coordinates := [][][]float64{ringToCoords(exterior)}
	for _, hole := range holes {
		coordinates = append(coordinates, ringToCoords(hole))
	}

	return &GeoJSONPolygon{
		Type:        "Polygon",
		Coordinates: coordinates,
	}
}

// ToWKTPoint converts nanodegree coordinates to a WKT POINT.
func ToWKTPoint(latNano, lonNano int64) string {
	return fmt.Sprintf("POINT(%g %g)", NanoToDegrees(lonNano), NanoToDegrees(latNano))
}

// ToWKTPolygon converts nanodegree coordinates to a WKT POLYGON.
func ToWKTPolygon(exterior [][2]int64, holes [][][2]int64) string {
	ringToWKT := func(ring [][2]int64) string {
		points := make([]string, len(ring))
		for i, point := range ring {
			points[i] = fmt.Sprintf("%g %g", NanoToDegrees(point[1]), NanoToDegrees(point[0]))
		}
		return "(" + strings.Join(points, ", ") + ")"
	}

	rings := []string{ringToWKT(exterior)}
	for _, hole := range holes {
		rings = append(rings, ringToWKT(hole))
	}

	return "POLYGON(" + strings.Join(rings, ", ") + ")"
}

// validateCoordinates checks that lat/lon are within valid bounds.
func validateCoordinates(lat, lon float64) error {
	if lat < -90 || lat > 90 {
		return &GeoFormatError{Message: fmt.Sprintf("latitude %g out of bounds [-90, 90]", lat)}
	}
	if lon < -180 || lon > 180 {
		return &GeoFormatError{Message: fmt.Sprintf("longitude %g out of bounds [-180, 180]", lon)}
	}
	return nil
}

// IsGeoFormatError checks if an error is a GeoFormatError.
func IsGeoFormatError(err error) bool {
	var geoErr *GeoFormatError
	return errors.As(err, &geoErr)
}
