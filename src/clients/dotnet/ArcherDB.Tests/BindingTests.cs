using Microsoft.VisualStudio.TestTools.UnitTesting;
using System;

namespace ArcherDB.Tests;

[TestClass]
public class BindingTests
{
    [TestMethod]
    public void GeoEventFields()
    {
        var geoEvent = new GeoEvent();

        geoEvent.Id = 100;
        Assert.AreEqual((UInt128)100, geoEvent.Id);

        geoEvent.EntityId = 101;
        Assert.AreEqual((UInt128)101, geoEvent.EntityId);

        geoEvent.CorrelationId = 102;
        Assert.AreEqual((UInt128)102, geoEvent.CorrelationId);

        geoEvent.UserData = 103;
        Assert.AreEqual((UInt128)103, geoEvent.UserData);

        geoEvent.LatNano = 37_774_900_000L;
        Assert.AreEqual(37_774_900_000L, geoEvent.LatNano);

        geoEvent.LonNano = -122_419_400_000L;
        Assert.AreEqual(-122_419_400_000L, geoEvent.LonNano);

        geoEvent.GroupId = 42;
        Assert.AreEqual(42UL, geoEvent.GroupId);

        geoEvent.Timestamp = 0;
        Assert.AreEqual(0UL, geoEvent.Timestamp);

        geoEvent.AltitudeMm = 123;
        Assert.AreEqual(123, geoEvent.AltitudeMm);

        geoEvent.VelocityMms = 456;
        Assert.AreEqual(456U, geoEvent.VelocityMms);

        geoEvent.TtlSeconds = 789;
        Assert.AreEqual(789U, geoEvent.TtlSeconds);

        geoEvent.AccuracyMm = 321;
        Assert.AreEqual(321U, geoEvent.AccuracyMm);

        geoEvent.HeadingCdeg = 1234;
        Assert.AreEqual((ushort)1234, geoEvent.HeadingCdeg);

        var flags = GeoEventFlags.Linked | GeoEventFlags.Stationary;
        geoEvent.Flags = flags;
        Assert.AreEqual(flags, geoEvent.Flags);
    }

    [TestMethod]
    public void GeoEventDefault()
    {
        var geoEvent = new GeoEvent();

        Assert.AreEqual(UInt128.Zero, geoEvent.Id);
        Assert.AreEqual(UInt128.Zero, geoEvent.EntityId);
        Assert.AreEqual(UInt128.Zero, geoEvent.CorrelationId);
        Assert.AreEqual(UInt128.Zero, geoEvent.UserData);
        Assert.AreEqual(0L, geoEvent.LatNano);
        Assert.AreEqual(0L, geoEvent.LonNano);
        Assert.AreEqual(0UL, geoEvent.GroupId);
        Assert.AreEqual(0UL, geoEvent.Timestamp);
        Assert.AreEqual(0, geoEvent.AltitudeMm);
        Assert.AreEqual(0U, geoEvent.VelocityMms);
        Assert.AreEqual(0U, geoEvent.TtlSeconds);
        Assert.AreEqual(0U, geoEvent.AccuracyMm);
        Assert.AreEqual((ushort)0, geoEvent.HeadingCdeg);
        Assert.AreEqual(GeoEventFlags.None, geoEvent.Flags);
    }

    [TestMethod]
    public void InsertGeoEventsResultFields()
    {
        var result = new InsertGeoEventsResult();

        result.Index = 1;
        result.Result = InsertGeoEventResult.Exists;

        Assert.AreEqual(1U, result.Index);
        Assert.AreEqual(InsertGeoEventResult.Exists, result.Result);
    }
}
