// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

/////////////////////////////////////////////////////////////
// Polygon Self-Intersection Validation                      //
// per add-polygon-validation spec                           //
/////////////////////////////////////////////////////////////

using System;
using System.Collections.Generic;

namespace ArcherDB;

/// <summary>
/// Exception thrown when a polygon self-intersects.
/// </summary>
public class PolygonValidationException : Exception
{
    /// <summary>
    /// Index of the first intersecting segment (0-based).
    /// </summary>
    public int Segment1Index { get; }

    /// <summary>
    /// Index of the second intersecting segment (0-based).
    /// </summary>
    public int Segment2Index { get; }

    /// <summary>
    /// Approximate intersection point [lat, lon] in degrees.
    /// </summary>
    public (double Lat, double Lon) IntersectionPoint { get; }

    /// <summary>
    /// Creates a new PolygonValidationException.
    /// </summary>
    public PolygonValidationException(
        string message,
        int segment1Index = -1,
        int segment2Index = -1,
        (double Lat, double Lon) intersectionPoint = default)
        : base(message)
    {
        Segment1Index = segment1Index;
        Segment2Index = segment2Index;
        IntersectionPoint = intersectionPoint;
    }
}

/// <summary>
/// Information about a detected self-intersection.
/// </summary>
public class IntersectionInfo
{
    /// <summary>
    /// Index of the first intersecting segment.
    /// </summary>
    public int Segment1Index { get; }

    /// <summary>
    /// Index of the second intersecting segment.
    /// </summary>
    public int Segment2Index { get; }

    /// <summary>
    /// Approximate intersection point [lat, lon] in degrees.
    /// </summary>
    public (double Lat, double Lon) IntersectionPoint { get; }

    /// <summary>
    /// Creates a new IntersectionInfo.
    /// </summary>
    public IntersectionInfo(int segment1Index, int segment2Index, (double Lat, double Lon) intersectionPoint)
    {
        Segment1Index = segment1Index;
        Segment2Index = segment2Index;
        IntersectionPoint = intersectionPoint;
    }
}

/// <summary>
/// Polygon self-intersection validation utilities.
/// </summary>
public static class PolygonValidation
{
    private const double Eps = 1e-10;

    /// <summary>
    /// Checks if two line segments intersect.
    /// Uses the cross product method with proper handling of collinear cases.
    /// </summary>
    /// <param name="p1">First segment start point (lat, lon)</param>
    /// <param name="p2">First segment end point (lat, lon)</param>
    /// <param name="p3">Second segment start point (lat, lon)</param>
    /// <param name="p4">Second segment end point (lat, lon)</param>
    /// <returns>True if the segments intersect, false otherwise</returns>
    public static bool SegmentsIntersect(
        (double Lat, double Lon) p1,
        (double Lat, double Lon) p2,
        (double Lat, double Lon) p3,
        (double Lat, double Lon) p4)
    {
        static double CrossProduct((double Lat, double Lon) o, (double Lat, double Lon) a, (double Lat, double Lon) b)
            => (a.Lat - o.Lat) * (b.Lon - o.Lon) - (a.Lon - o.Lon) * (b.Lat - o.Lat);

        static bool OnSegment((double Lat, double Lon) p, (double Lat, double Lon) q, (double Lat, double Lon) r)
            => q.Lat >= Math.Min(p.Lat, r.Lat) && q.Lat <= Math.Max(p.Lat, r.Lat) &&
               q.Lon >= Math.Min(p.Lon, r.Lon) && q.Lon <= Math.Max(p.Lon, r.Lon);

        var d1 = CrossProduct(p3, p4, p1);
        var d2 = CrossProduct(p3, p4, p2);
        var d3 = CrossProduct(p1, p2, p3);
        var d4 = CrossProduct(p1, p2, p4);

        // General case: segments cross
        if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
            ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)))
        {
            return true;
        }

        // Collinear cases
        if (Math.Abs(d1) < Eps && OnSegment(p3, p1, p4)) return true;
        if (Math.Abs(d2) < Eps && OnSegment(p3, p2, p4)) return true;
        if (Math.Abs(d3) < Eps && OnSegment(p1, p3, p2)) return true;
        if (Math.Abs(d4) < Eps && OnSegment(p1, p4, p2)) return true;

        return false;
    }

    /// <summary>
    /// Validates that a polygon has no self-intersections.
    /// Uses an O(n^2) algorithm suitable for polygons with reasonable vertex counts.
    /// </summary>
    /// <param name="vertices">List of (lat, lon) coordinate pairs in degrees</param>
    /// <param name="raiseOnError">If true, throws PolygonValidationException on first intersection</param>
    /// <returns>List of all intersections found (empty if valid)</returns>
    /// <exception cref="PolygonValidationException">Thrown if raiseOnError is true and polygon self-intersects</exception>
    public static List<IntersectionInfo> ValidatePolygonNoSelfIntersection(
        IList<(double Lat, double Lon)> vertices,
        bool raiseOnError = true)
    {
        var intersections = new List<IntersectionInfo>();

        // A triangle cannot self-intersect (3 vertices = 3 edges, need at least 4 for crossing)
        if (vertices.Count < 4)
        {
            return intersections;
        }

        int n = vertices.Count;

        // Check all pairs of non-adjacent edges
        for (int i = 0; i < n; i++)
        {
            var p1 = vertices[i];
            var p2 = vertices[(i + 1) % n];

            // Start from i+2 to skip adjacent edges (they share a vertex)
            for (int j = i + 2; j < n; j++)
            {
                // Skip if edges share a vertex (adjacent edges)
                if (j == (i + n - 1) % n)
                {
                    continue;
                }

                var p3 = vertices[j];
                var p4 = vertices[(j + 1) % n];

                if (SegmentsIntersect(p1, p2, p3, p4))
                {
                    // Calculate approximate intersection point for error message
                    var ix = (p1.Lat + p2.Lat + p3.Lat + p4.Lat) / 4.0;
                    var iy = (p1.Lon + p2.Lon + p3.Lon + p4.Lon) / 4.0;
                    var intersection = (ix, iy);

                    if (raiseOnError)
                    {
                        throw new PolygonValidationException(
                            $"Polygon self-intersects: edge {i}-{(i + 1) % n} crosses edge {j}-{(j + 1) % n} near ({ix:F6}, {iy:F6})",
                            i, j, intersection);
                    }

                    intersections.Add(new IntersectionInfo(i, j, intersection));
                }
            }
        }

        return intersections;
    }
}
