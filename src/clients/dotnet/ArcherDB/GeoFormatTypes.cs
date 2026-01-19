// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

/////////////////////////////////////////////////////////////
// GeoJSON/WKT Protocol Support                             //
// per add-geojson-wkt-protocol spec                        //
/////////////////////////////////////////////////////////////

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace ArcherDB;

/// <summary>
/// Exception thrown when parsing GeoJSON or WKT format fails.
/// </summary>
public class GeoFormatException : Exception
{
    /// <summary>
    /// Creates a new GeoFormatException with the specified message.
    /// </summary>
    public GeoFormatException(string message) : base(message) { }

    /// <summary>
    /// Creates a new GeoFormatException with the specified message and inner exception.
    /// </summary>
    public GeoFormatException(string message, Exception inner) : base(message, inner) { }
}

/// <summary>
/// Output format for geographic data.
/// </summary>
public enum GeoFormat : byte
{
    /// <summary>
    /// Native nanodegree format.
    /// </summary>
    Native = 0,

    /// <summary>
    /// GeoJSON format.
    /// </summary>
    GeoJson = 1,

    /// <summary>
    /// Well-Known Text format.
    /// </summary>
    Wkt = 2,
}

/// <summary>
/// Result of parsing a GeoJSON or WKT Polygon.
/// </summary>
public class PolygonParseResult
{
    /// <summary>
    /// Exterior ring as list of (lat_nano, lon_nano) tuples.
    /// </summary>
    public List<(long LatNano, long LonNano)> Exterior { get; set; } = new();

    /// <summary>
    /// Holes as list of rings, each ring is a list of (lat_nano, lon_nano) tuples.
    /// </summary>
    public List<List<(long LatNano, long LonNano)>> Holes { get; set; } = new();
}

/// <summary>
/// GeoJSON and WKT parsing and formatting utilities.
/// </summary>
public static class GeoFormatParser
{
    private const double LatMax = 90.0;
    private const double LonMax = 180.0;
    private const long NanodegreesPerDegree = 1_000_000_000L;

    private static readonly Regex WktPointPattern = new Regex(
        @"(?i)^\s*POINT\s*\(\s*([\d.\-]+)\s+([\d.\-]+)(?:\s+[\d.\-]+)?\s*\)\s*$",
        RegexOptions.Compiled
    );

    /// <summary>
    /// Parses a GeoJSON Point to nanodegree coordinates.
    /// </summary>
    /// <param name="geojson">GeoJSON Point string</param>
    /// <returns>Tuple of (lat_nano, lon_nano)</returns>
    /// <exception cref="GeoFormatException">If parsing fails</exception>
    public static (long LatNano, long LonNano) ParseGeoJSONPoint(string geojson)
    {
        if (string.IsNullOrWhiteSpace(geojson))
            throw new GeoFormatException("GeoJSON string is null or empty");

        // Simple JSON parsing without external dependencies
        string trimmed = geojson.Trim();

        // Check type field
        if (!trimmed.Contains("\"type\"") || !trimmed.Contains("\"Point\""))
            throw new GeoFormatException("Expected type 'Point' in GeoJSON");

        // Extract coordinates array
        int coordsStart = trimmed.IndexOf("\"coordinates\"");
        if (coordsStart == -1)
            throw new GeoFormatException("Missing 'coordinates' field");

        int arrayStart = trimmed.IndexOf('[', coordsStart);
        int arrayEnd = trimmed.IndexOf(']', arrayStart);
        if (arrayStart == -1 || arrayEnd == -1)
            throw new GeoFormatException("Invalid coordinates array");

        string coordsStr = trimmed.Substring(arrayStart + 1, arrayEnd - arrayStart - 1);
        string[] parts = coordsStr.Split(',');
        if (parts.Length < 2)
            throw new GeoFormatException("Point must have [lon, lat] coordinates");

        if (!double.TryParse(parts[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out double lon))
            throw new GeoFormatException("Invalid longitude value");
        if (!double.TryParse(parts[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out double lat))
            throw new GeoFormatException("Invalid latitude value");

        ValidateCoordinates(lat, lon);

        return (DegreesToNano(lat), DegreesToNano(lon));
    }

    /// <summary>
    /// Parses a GeoJSON Polygon to nanodegree coordinates.
    /// </summary>
    /// <param name="geojson">GeoJSON Polygon string</param>
    /// <returns>PolygonParseResult containing exterior and holes</returns>
    /// <exception cref="GeoFormatException">If parsing fails</exception>
    public static PolygonParseResult ParseGeoJSONPolygon(string geojson)
    {
        if (string.IsNullOrWhiteSpace(geojson))
            throw new GeoFormatException("GeoJSON string is null or empty");

        string trimmed = geojson.Trim();

        // Check type field
        if (!trimmed.Contains("\"type\"") || !trimmed.Contains("\"Polygon\""))
            throw new GeoFormatException("Expected type 'Polygon' in GeoJSON");

        // Find coordinates array
        int coordsStart = trimmed.IndexOf("\"coordinates\"");
        if (coordsStart == -1)
            throw new GeoFormatException("Missing 'coordinates' field");

        int outerStart = trimmed.IndexOf('[', coordsStart);
        if (outerStart == -1)
            throw new GeoFormatException("Invalid coordinates array");

        // Parse the nested arrays
        var rings = new List<List<(long, long)>>();
        int depth = 0;
        var currentRing = new List<(long, long)>();
        var currentPoint = new List<double>();
        var currentNumber = new StringBuilder();
        bool inNumber = false;

        for (int i = outerStart; i < trimmed.Length; i++)
        {
            char c = trimmed[i];

            if (c == '[')
            {
                depth++;
                if (depth == 2)
                    currentRing = new List<(long, long)>();
                else if (depth == 3)
                    currentPoint = new List<double>();
            }
            else if (c == ']')
            {
                if (inNumber && currentNumber.Length > 0)
                {
                    if (double.TryParse(currentNumber.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out double num))
                        currentPoint.Add(num);
                    currentNumber.Clear();
                    inNumber = false;
                }

                if (depth == 3 && currentPoint.Count >= 2)
                {
                    double lon = currentPoint[0];
                    double lat = currentPoint[1];
                    ValidateCoordinates(lat, lon);
                    currentRing.Add((DegreesToNano(lat), DegreesToNano(lon)));
                }
                if (depth == 2 && currentRing.Count >= 3)
                {
                    rings.Add(currentRing);
                }

                depth--;
                if (depth == 0) break;
            }
            else if (char.IsDigit(c) || c == '.' || c == '-' || c == 'e' || c == 'E' || c == '+')
            {
                if (!inNumber && depth >= 3)
                {
                    inNumber = true;
                    currentNumber.Clear();
                }
                if (inNumber)
                    currentNumber.Append(c);
            }
            else if (c == ',' && depth == 3)
            {
                if (inNumber && currentNumber.Length > 0)
                {
                    if (double.TryParse(currentNumber.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out double num))
                        currentPoint.Add(num);
                    currentNumber.Clear();
                    inNumber = false;
                }
            }
        }

        if (rings.Count == 0)
            throw new GeoFormatException("Polygon must have at least one ring");

        var result = new PolygonParseResult
        {
            Exterior = rings[0]
        };

        for (int i = 1; i < rings.Count; i++)
            result.Holes.Add(rings[i]);

        return result;
    }

    /// <summary>
    /// Parses a WKT POINT to nanodegree coordinates.
    /// </summary>
    /// <param name="wkt">WKT string like "POINT(lon lat)"</param>
    /// <returns>Tuple of (lat_nano, lon_nano)</returns>
    /// <exception cref="GeoFormatException">If parsing fails</exception>
    public static (long LatNano, long LonNano) ParseWKTPoint(string wkt)
    {
        if (string.IsNullOrWhiteSpace(wkt))
            throw new GeoFormatException("WKT string is null or empty");

        var match = WktPointPattern.Match(wkt);
        if (!match.Success)
            throw new GeoFormatException("Invalid WKT POINT format");

        if (!double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double lon))
            throw new GeoFormatException("Invalid longitude value");
        if (!double.TryParse(match.Groups[2].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double lat))
            throw new GeoFormatException("Invalid latitude value");

        ValidateCoordinates(lat, lon);

        return (DegreesToNano(lat), DegreesToNano(lon));
    }

    /// <summary>
    /// Parses a WKT POLYGON to nanodegree coordinates.
    /// </summary>
    /// <param name="wkt">WKT string like "POLYGON((lon lat, lon lat, ...))"</param>
    /// <returns>PolygonParseResult containing exterior and holes</returns>
    /// <exception cref="GeoFormatException">If parsing fails</exception>
    public static PolygonParseResult ParseWKTPolygon(string wkt)
    {
        if (string.IsNullOrWhiteSpace(wkt))
            throw new GeoFormatException("WKT string is null or empty");

        string upper = wkt.Trim().ToUpperInvariant();
        if (!upper.StartsWith("POLYGON"))
            throw new GeoFormatException("Expected POLYGON");

        int outerStart = wkt.IndexOf('(');
        int outerEnd = wkt.LastIndexOf(')');
        if (outerStart == -1 || outerEnd == -1 || outerStart >= outerEnd)
            throw new GeoFormatException("Invalid WKT POLYGON: missing parentheses");

        string content = wkt.Substring(outerStart + 1, outerEnd - outerStart - 1);

        // Find matching parentheses for each ring
        var ringStrs = new List<string>();
        int depth = 0;
        int ringStart = 0;
        for (int i = 0; i < content.Length; i++)
        {
            char c = content[i];
            if (c == '(')
            {
                if (depth == 0) ringStart = i;
                depth++;
            }
            else if (c == ')')
            {
                depth--;
                if (depth == 0)
                    ringStrs.Add(content.Substring(ringStart, i - ringStart + 1));
            }
        }

        if (ringStrs.Count == 0)
            throw new GeoFormatException("POLYGON must have at least one ring");

        var rings = new List<List<(long, long)>>();
        foreach (var ringStr in ringStrs)
            rings.Add(ParseWKTRing(ringStr));

        var result = new PolygonParseResult
        {
            Exterior = rings[0]
        };

        for (int i = 1; i < rings.Count; i++)
            result.Holes.Add(rings[i]);

        return result;
    }

    private static List<(long, long)> ParseWKTRing(string ring)
    {
        ring = ring.Trim();
        if (!ring.StartsWith("(") || !ring.EndsWith(")"))
            throw new GeoFormatException("Ring must be enclosed in parentheses");

        string content = ring.Substring(1, ring.Length - 2);
        string[] pointStrs = content.Split(',');

        if (pointStrs.Length < 3)
            throw new GeoFormatException($"Ring must have at least 3 vertices, got {pointStrs.Length}");

        var result = new List<(long, long)>();
        for (int i = 0; i < pointStrs.Length; i++)
        {
            string[] parts = pointStrs[i].Trim().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2)
                throw new GeoFormatException($"Invalid point at index {i}");

            if (!double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double lon))
                throw new GeoFormatException($"Invalid longitude at point {i}");
            if (!double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double lat))
                throw new GeoFormatException($"Invalid latitude at point {i}");

            ValidateCoordinates(lat, lon);

            result.Add((DegreesToNano(lat), DegreesToNano(lon)));
        }

        return result;
    }

    /// <summary>
    /// Converts nanodegree coordinates to a GeoJSON Point string.
    /// </summary>
    public static string ToGeoJSONPoint(long latNano, long lonNano)
    {
        double lat = NanoToDegrees(latNano);
        double lon = NanoToDegrees(lonNano);
        return $"{{\"type\":\"Point\",\"coordinates\":[{lon.ToString(CultureInfo.InvariantCulture)},{lat.ToString(CultureInfo.InvariantCulture)}]}}";
    }

    /// <summary>
    /// Converts nanodegree coordinates to a GeoJSON Polygon string.
    /// </summary>
    public static string ToGeoJSONPolygon(List<(long LatNano, long LonNano)> exterior, List<List<(long LatNano, long LonNano)>>? holes = null)
    {
        var sb = new StringBuilder();
        sb.Append("{\"type\":\"Polygon\",\"coordinates\":[");

        AppendRingAsGeoJSON(sb, exterior);

        if (holes != null)
        {
            foreach (var hole in holes)
            {
                sb.Append(",");
                AppendRingAsGeoJSON(sb, hole);
            }
        }

        sb.Append("]}");
        return sb.ToString();
    }

    private static void AppendRingAsGeoJSON(StringBuilder sb, List<(long LatNano, long LonNano)> ring)
    {
        sb.Append("[");
        bool first = true;
        foreach (var (latNano, lonNano) in ring)
        {
            if (!first) sb.Append(",");
            first = false;
            sb.Append("[");
            sb.Append(NanoToDegrees(lonNano).ToString(CultureInfo.InvariantCulture));
            sb.Append(",");
            sb.Append(NanoToDegrees(latNano).ToString(CultureInfo.InvariantCulture));
            sb.Append("]");
        }
        sb.Append("]");
    }

    /// <summary>
    /// Converts nanodegree coordinates to a WKT POINT string.
    /// </summary>
    public static string ToWKTPoint(long latNano, long lonNano)
    {
        double lat = NanoToDegrees(latNano);
        double lon = NanoToDegrees(lonNano);
        return $"POINT({lon.ToString(CultureInfo.InvariantCulture)} {lat.ToString(CultureInfo.InvariantCulture)})";
    }

    /// <summary>
    /// Converts nanodegree coordinates to a WKT POLYGON string.
    /// </summary>
    public static string ToWKTPolygon(List<(long LatNano, long LonNano)> exterior, List<List<(long LatNano, long LonNano)>>? holes = null)
    {
        var sb = new StringBuilder();
        sb.Append("POLYGON(");

        AppendRingAsWKT(sb, exterior);

        if (holes != null)
        {
            foreach (var hole in holes)
            {
                sb.Append(", ");
                AppendRingAsWKT(sb, hole);
            }
        }

        sb.Append(")");
        return sb.ToString();
    }

    private static void AppendRingAsWKT(StringBuilder sb, List<(long LatNano, long LonNano)> ring)
    {
        sb.Append("(");
        bool first = true;
        foreach (var (latNano, lonNano) in ring)
        {
            if (!first) sb.Append(", ");
            first = false;
            sb.Append(NanoToDegrees(lonNano).ToString(CultureInfo.InvariantCulture));
            sb.Append(" ");
            sb.Append(NanoToDegrees(latNano).ToString(CultureInfo.InvariantCulture));
        }
        sb.Append(")");
    }

    /// <summary>
    /// Converts degrees to nanodegrees.
    /// </summary>
    public static long DegreesToNano(double degrees)
    {
        return (long)Math.Round(degrees * NanodegreesPerDegree);
    }

    /// <summary>
    /// Converts nanodegrees to degrees.
    /// </summary>
    public static double NanoToDegrees(long nano)
    {
        return (double)nano / NanodegreesPerDegree;
    }

    private static void ValidateCoordinates(double lat, double lon)
    {
        if (lat < -LatMax || lat > LatMax)
            throw new GeoFormatException($"Latitude {lat} out of bounds [-90, 90]");
        if (lon < -LonMax || lon > LonMax)
            throw new GeoFormatException($"Longitude {lon} out of bounds [-180, 180]");
    }
}
