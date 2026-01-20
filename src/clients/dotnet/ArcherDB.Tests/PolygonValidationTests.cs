// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

/////////////////////////////////////////////////////////////
// Tests for Polygon Self-Intersection Validation            //
// per add-polygon-validation spec                           //
/////////////////////////////////////////////////////////////

using System;
using System.Collections.Generic;
using Xunit;

namespace ArcherDB.Tests;

public class PolygonValidationTests
{
    [Fact]
    public void ValidTriangle_NoIntersections()
    {
        // Triangle cannot self-intersect (too few edges)
        var triangle = new List<(double, double)>
        {
            (0.0, 0.0),
            (1.0, 0.0),
            (0.5, 1.0),
        };
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(triangle, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void ValidSquare_NoIntersections()
    {
        // Simple square has no self-intersections
        var square = new List<(double, double)>
        {
            (0.0, 0.0),
            (1.0, 0.0),
            (1.0, 1.0),
            (0.0, 1.0),
        };
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(square, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void ValidConvexPentagon_NoIntersections()
    {
        // Convex pentagon has no self-intersections
        var pentagon = new List<(double, double)>();
        for (int i = 0; i < 5; i++)
        {
            double angle = 2.0 * Math.PI * i / 5.0;
            pentagon.Add((Math.Cos(angle), Math.Sin(angle)));
        }
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(pentagon, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void BowtiePolygon_HasIntersections()
    {
        // Bow-tie (figure-8) polygon has a self-intersection
        var bowtie = new List<(double, double)>
        {
            (0.0, 0.0),
            (1.0, 1.0),
            (1.0, 0.0),
            (0.0, 1.0),
        };
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(bowtie, raiseOnError: false);
        Assert.NotEmpty(result);
    }

    [Fact]
    public void BowtiePolygon_ThrowsException()
    {
        // Bow-tie polygon throws exception when raiseOnError=true
        var bowtie = new List<(double, double)>
        {
            (0.0, 0.0),
            (1.0, 1.0),
            (1.0, 0.0),
            (0.0, 1.0),
        };

        var ex = Assert.Throws<PolygonValidationException>(() =>
            PolygonValidation.ValidatePolygonNoSelfIntersection(bowtie, raiseOnError: true));

        Assert.InRange(ex.Segment1Index, 0, 3);
        Assert.InRange(ex.Segment2Index, 0, 3);
        Assert.Contains("self-intersects", ex.Message);
    }

    [Fact]
    public void ValidConcavePolygon_NoIntersections()
    {
        // Concave (non-convex) polygon without self-intersections (L-shape)
        var lShape = new List<(double, double)>
        {
            (0.0, 0.0),
            (2.0, 0.0),
            (2.0, 1.0),
            (1.0, 1.0),
            (1.0, 2.0),
            (0.0, 2.0),
        };
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(lShape, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void StarPolygon_HasIntersections()
    {
        // 5-pointed star (drawn without lifting pen) self-intersects
        var star = new List<(double, double)>();
        for (int i = 0; i < 5; i++)
        {
            double angle = Math.PI / 2.0 + i * 4.0 * Math.PI / 5.0;
            star.Add((Math.Cos(angle), Math.Sin(angle)));
        }
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(star, raiseOnError: false);
        Assert.NotEmpty(result);
    }

    [Fact]
    public void SegmentsIntersect_CrossingSegments()
    {
        // Clearly crossing segments
        Assert.True(PolygonValidation.SegmentsIntersect(
            (0.0, 0.0), (1.0, 1.0),  // Diagonal
            (0.0, 1.0), (1.0, 0.0)   // Opposite diagonal
        ));
    }

    [Fact]
    public void SegmentsIntersect_ParallelSegments()
    {
        // Parallel segments (no intersection)
        Assert.False(PolygonValidation.SegmentsIntersect(
            (0.0, 0.0), (1.0, 0.0),  // Horizontal
            (0.0, 1.0), (1.0, 1.0)   // Parallel horizontal
        ));
    }

    [Fact]
    public void SegmentsIntersect_TJunction()
    {
        // T-junction (endpoint touches)
        Assert.True(PolygonValidation.SegmentsIntersect(
            (0.0, 0.5), (1.0, 0.5),  // Horizontal
            (0.5, 0.0), (0.5, 0.5)   // Vertical ending at intersection
        ));
    }

    [Fact]
    public void PolygonValidationException_HasCorrectAttributes()
    {
        var ex = new PolygonValidationException(
            "Test error",
            segment1Index: 1,
            segment2Index: 3,
            intersectionPoint: (0.5, 0.5));

        Assert.Equal(1, ex.Segment1Index);
        Assert.Equal(3, ex.Segment2Index);
        Assert.Equal(0.5, ex.IntersectionPoint.Lat, 3);
        Assert.Equal(0.5, ex.IntersectionPoint.Lon, 3);
        Assert.Contains("Test error", ex.Message);
    }

    [Fact]
    public void EmptyPolygon_NoIntersections()
    {
        var empty = new List<(double, double)>();
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(empty, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void SinglePoint_NoIntersections()
    {
        var single = new List<(double, double)> { (0, 0) };
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(single, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void TwoPoints_NoIntersections()
    {
        var line = new List<(double, double)> { (0, 0), (1, 1) };
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(line, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void ThreePoints_NoIntersections()
    {
        var triangle = new List<(double, double)> { (0, 0), (1, 0), (0, 1) };
        var result = PolygonValidation.ValidatePolygonNoSelfIntersection(triangle, raiseOnError: false);
        Assert.Empty(result);
    }

    [Fact]
    public void RepairSuggestions_IncludedInException()
    {
        // Bow-tie polygon should include repair suggestions
        var bowtie = new List<(double, double)>
        {
            (0.0, 0.0),
            (1.0, 1.0),
            (1.0, 0.0),
            (0.0, 1.0),
        };

        var ex = Assert.Throws<PolygonValidationException>(() =>
            PolygonValidation.ValidatePolygonNoSelfIntersection(bowtie, raiseOnError: true));

        Assert.NotEmpty(ex.RepairSuggestions);
        Assert.True(ex.RepairSuggestions.Count >= 3, "Should have at least 3 suggestions");
        Assert.Contains(ex.RepairSuggestions, s => s.Contains("Try removing vertex"));
        Assert.Contains(ex.RepairSuggestions, s => s.Contains("vertices are ordered"));
    }

    [Fact]
    public void RepairSuggestions_GetRepairSuggestionsMethod()
    {
        // Test GetRepairSuggestions() method
        var bowtie = new List<(double, double)>
        {
            (0.0, 0.0),
            (1.0, 1.0),
            (1.0, 0.0),
            (0.0, 1.0),
        };

        var ex = Assert.Throws<PolygonValidationException>(() =>
            PolygonValidation.ValidatePolygonNoSelfIntersection(bowtie, raiseOnError: true));

        var suggestions = ex.GetRepairSuggestions();
        Assert.NotEmpty(suggestions);
        Assert.Equal(ex.RepairSuggestions, suggestions);
    }

    [Fact]
    public void RepairSuggestions_BowtiePatternDetected()
    {
        // Bow-tie polygon should have bow-tie specific suggestion
        var bowtie = new List<(double, double)>
        {
            (0.0, 0.0),
            (1.0, 1.0),
            (1.0, 0.0),
            (0.0, 1.0),
        };

        var ex = Assert.Throws<PolygonValidationException>(() =>
            PolygonValidation.ValidatePolygonNoSelfIntersection(bowtie, raiseOnError: true));

        Assert.Contains(ex.RepairSuggestions, s => s.Contains("Bow-tie pattern detected"));
    }

    [Fact]
    public void RepairSuggestions_DefaultsToEmpty()
    {
        // Exception without suggestions should have empty list
        var ex = new PolygonValidationException("Test error");
        Assert.Empty(ex.RepairSuggestions);
        Assert.Empty(ex.GetRepairSuggestions());
    }
}
