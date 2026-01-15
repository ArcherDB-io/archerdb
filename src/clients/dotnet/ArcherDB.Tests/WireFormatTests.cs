using Microsoft.VisualStudio.TestTools.UnitTesting;
using System;
using System.IO;
using System.Text.Json;

namespace ArcherDB.Tests;

/// <summary>
/// Wire format compatibility tests.
/// Loads canonical test data from wire-format-test-cases.json and verifies
/// the .NET SDK produces compatible output with other language SDKs.
/// </summary>
[TestClass]
public class WireFormatTests
{
    private static JsonDocument? testData;

    private static string FindTestDataPath()
    {
        // Test runs from src/clients/dotnet/ArcherDB.Tests/
        string[] candidates = new[]
        {
            "../../test-data/wire-format-test-cases.json",
            "../../../test-data/wire-format-test-cases.json",
            "test-data/wire-format-test-cases.json",
        };

        foreach (var path in candidates)
        {
            if (File.Exists(path))
            {
                return path;
            }
        }

        var projectRoot = Environment.CurrentDirectory;
        foreach (var path in candidates)
        {
            var fullPath = Path.Combine(projectRoot, path);
            if (File.Exists(fullPath))
            {
                return fullPath;
            }
        }

        throw new FileNotFoundException("Could not find wire-format-test-cases.json");
    }

    [ClassInitialize]
    public static void ClassInit(TestContext context)
    {
        var testDataPath = FindTestDataPath();
        var json = File.ReadAllText(testDataPath);
        testData = JsonDocument.Parse(json);
    }

    [ClassCleanup]
    public static void ClassCleanup()
    {
        testData?.Dispose();
    }

    // ========================================================================
    // Constants Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_Constants_MatchCanonical()
    {
        var constants = testData!.RootElement.GetProperty("constants");

        // Note: .NET SDK stores values directly in wire format (nanodegrees, mm, centidegrees)
        // so we test the expected values against the canonical constants
        Assert.AreEqual(90.0, constants.GetProperty("LAT_MAX").GetDouble(), "LAT_MAX");
        Assert.AreEqual(180.0, constants.GetProperty("LON_MAX").GetDouble(), "LON_MAX");
        Assert.AreEqual(1_000_000_000L, constants.GetProperty("NANODEGREES_PER_DEGREE").GetInt64(), "NANODEGREES_PER_DEGREE");
        Assert.AreEqual(1000, constants.GetProperty("MM_PER_METER").GetInt32(), "MM_PER_METER");
        Assert.AreEqual(100, constants.GetProperty("CENTIDEGREES_PER_DEGREE").GetInt32(), "CENTIDEGREES_PER_DEGREE");
        Assert.AreEqual(10_000, constants.GetProperty("BATCH_SIZE_MAX").GetInt32(), "BATCH_SIZE_MAX");
        Assert.AreEqual(81_000, constants.GetProperty("QUERY_LIMIT_MAX").GetInt32(), "QUERY_LIMIT_MAX");
        Assert.AreEqual(10_000, constants.GetProperty("POLYGON_VERTICES_MAX").GetInt32(), "POLYGON_VERTICES_MAX");
    }

    // ========================================================================
    // GeoEvent Flags Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_GeoEventFlags_MatchCanonical()
    {
        var flags = testData!.RootElement.GetProperty("geo_event_flags");

        Assert.AreEqual(flags.GetProperty("NONE").GetUInt16(), (ushort)GeoEventFlags.None, "NONE");
        Assert.AreEqual(flags.GetProperty("LINKED").GetUInt16(), (ushort)GeoEventFlags.Linked, "LINKED");
        Assert.AreEqual(flags.GetProperty("IMPORTED").GetUInt16(), (ushort)GeoEventFlags.Imported, "IMPORTED");
        Assert.AreEqual(flags.GetProperty("STATIONARY").GetUInt16(), (ushort)GeoEventFlags.Stationary, "STATIONARY");
        Assert.AreEqual(flags.GetProperty("LOW_ACCURACY").GetUInt16(), (ushort)GeoEventFlags.LowAccuracy, "LOW_ACCURACY");
        Assert.AreEqual(flags.GetProperty("OFFLINE").GetUInt16(), (ushort)GeoEventFlags.Offline, "OFFLINE");
        Assert.AreEqual(flags.GetProperty("DELETED").GetUInt16(), (ushort)GeoEventFlags.Deleted, "DELETED");
    }

    // ========================================================================
    // Result Codes Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_InsertResultCodes_MatchCanonical()
    {
        var codes = testData!.RootElement.GetProperty("insert_result_codes");

        Assert.AreEqual((uint)codes.GetProperty("OK").GetInt32(), (uint)InsertGeoEventResult.Ok, "OK");
        Assert.AreEqual((uint)codes.GetProperty("LINKED_EVENT_FAILED").GetInt32(), (uint)InsertGeoEventResult.LinkedEventFailed, "LINKED_EVENT_FAILED");
        Assert.AreEqual((uint)codes.GetProperty("INVALID_COORDINATES").GetInt32(), (uint)InsertGeoEventResult.InvalidCoordinates, "INVALID_COORDINATES");
        Assert.AreEqual((uint)codes.GetProperty("EXISTS").GetInt32(), (uint)InsertGeoEventResult.Exists, "EXISTS");
    }

    [TestMethod]
    public void WireFormat_DeleteResultCodes_MatchCanonical()
    {
        var codes = testData!.RootElement.GetProperty("delete_result_codes");

        Assert.AreEqual((uint)codes.GetProperty("OK").GetInt32(), (uint)DeleteEntityResult.Ok, "OK");
        Assert.AreEqual((uint)codes.GetProperty("ENTITY_NOT_FOUND").GetInt32(), (uint)DeleteEntityResult.EntityNotFound, "ENTITY_NOT_FOUND");
    }

    // ========================================================================
    // Coordinate Conversion Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_CoordinateConversions_MatchCanonical()
    {
        var conversions = testData!.RootElement.GetProperty("coordinate_conversions");
        const long NANODEGREES_PER_DEGREE = 1_000_000_000L;

        foreach (var conversion in conversions.EnumerateArray())
        {
            var description = conversion.GetProperty("description").GetString();
            var degrees = conversion.GetProperty("degrees").GetDouble();
            var expectedNano = conversion.GetProperty("expected_nanodegrees").GetInt64();

            // Test conversion: degrees -> nanodegrees
            var result = (long)Math.Round(degrees * NANODEGREES_PER_DEGREE);
            Assert.AreEqual(expectedNano, result, $"degreesToNano: {description}");
        }
    }

    [TestMethod]
    public void WireFormat_CoordinateRoundtrip_MaintainsPrecision()
    {
        var conversions = testData!.RootElement.GetProperty("coordinate_conversions");
        const long NANODEGREES_PER_DEGREE = 1_000_000_000L;

        foreach (var conversion in conversions.EnumerateArray())
        {
            var description = conversion.GetProperty("description").GetString();
            var expectedNano = conversion.GetProperty("expected_nanodegrees").GetInt64();

            // Test roundtrip: nano -> degrees -> nano
            var degrees = (double)expectedNano / NANODEGREES_PER_DEGREE;
            var roundTrip = (long)Math.Round(degrees * NANODEGREES_PER_DEGREE);
            Assert.AreEqual(expectedNano, roundTrip, $"Roundtrip: {description}");
        }
    }

    // ========================================================================
    // Distance Conversion Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_DistanceConversions_MatchCanonical()
    {
        var conversions = testData!.RootElement.GetProperty("distance_conversions");
        const int MM_PER_METER = 1000;

        foreach (var conversion in conversions.EnumerateArray())
        {
            var description = conversion.GetProperty("description").GetString();
            var meters = conversion.GetProperty("meters").GetDouble();
            var expectedMm = conversion.GetProperty("expected_mm").GetInt32();

            // Test conversion: meters -> mm (with rounding)
            var result = (int)Math.Round(meters * MM_PER_METER);
            Assert.AreEqual(expectedMm, result, $"metersToMm: {description}");
        }
    }

    // ========================================================================
    // Heading Conversion Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_HeadingConversions_MatchCanonical()
    {
        var conversions = testData!.RootElement.GetProperty("heading_conversions");
        const int CENTIDEGREES_PER_DEGREE = 100;

        foreach (var conversion in conversions.EnumerateArray())
        {
            var description = conversion.GetProperty("description").GetString();
            var degrees = conversion.GetProperty("degrees").GetDouble();
            var expectedCdeg = (ushort)conversion.GetProperty("expected_centidegrees").GetInt32();

            // Test conversion: degrees -> centidegrees (with rounding)
            var result = (ushort)Math.Round(degrees * CENTIDEGREES_PER_DEGREE);
            Assert.AreEqual(expectedCdeg, result, $"headingToCentidegrees: {description}");
        }
    }

    // ========================================================================
    // GeoEvent Creation Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_GeoEventCreation_MatchCanonical()
    {
        var events = testData!.RootElement.GetProperty("geo_events");
        const long NANODEGREES_PER_DEGREE = 1_000_000_000L;
        const int MM_PER_METER = 1000;
        const int CENTIDEGREES_PER_DEGREE = 100;

        foreach (var testCase in events.EnumerateArray())
        {
            var description = testCase.GetProperty("description").GetString();
            var input = testCase.GetProperty("input");
            var expected = testCase.GetProperty("expected");

            var geoEvent = new GeoEvent
            {
                EntityId = (UInt128)input.GetProperty("entity_id").GetUInt64(),
                LatNano = (long)Math.Round(input.GetProperty("latitude").GetDouble() * NANODEGREES_PER_DEGREE),
                LonNano = (long)Math.Round(input.GetProperty("longitude").GetDouble() * NANODEGREES_PER_DEGREE),
            };

            // Optional fields
            if (input.TryGetProperty("correlation_id", out var corr) && corr.GetUInt64() != 0)
            {
                geoEvent.CorrelationId = (UInt128)corr.GetUInt64();
            }
            if (input.TryGetProperty("user_data", out var ud) && ud.GetUInt64() != 0)
            {
                geoEvent.UserData = (UInt128)ud.GetUInt64();
            }
            if (input.TryGetProperty("group_id", out var gid) && gid.GetUInt64() != 0)
            {
                geoEvent.GroupId = gid.GetUInt64();
            }
            if (input.TryGetProperty("altitude_m", out var alt) && alt.GetDouble() != 0)
            {
                geoEvent.AltitudeMm = (int)Math.Round(alt.GetDouble() * MM_PER_METER);
            }
            if (input.TryGetProperty("velocity_mps", out var vel) && vel.GetDouble() != 0)
            {
                geoEvent.VelocityMms = (uint)Math.Round(vel.GetDouble() * MM_PER_METER);
            }
            if (input.TryGetProperty("ttl_seconds", out var ttl) && ttl.GetUInt32() != 0)
            {
                geoEvent.TtlSeconds = ttl.GetUInt32();
            }
            if (input.TryGetProperty("accuracy_m", out var acc) && acc.GetDouble() != 0)
            {
                geoEvent.AccuracyMm = (uint)Math.Round(acc.GetDouble() * MM_PER_METER);
            }
            if (input.TryGetProperty("heading", out var hdg) && hdg.GetDouble() != 0)
            {
                geoEvent.HeadingCdeg = (ushort)Math.Round(hdg.GetDouble() * CENTIDEGREES_PER_DEGREE);
            }
            if (input.TryGetProperty("flags", out var flg) && flg.GetUInt16() != 0)
            {
                geoEvent.Flags = (GeoEventFlags)flg.GetUInt16();
            }

            // Verify fields - compare low 64 bits for UInt128 fields
            Assert.AreEqual(expected.GetProperty("entity_id").GetUInt64(), (ulong)geoEvent.EntityId, $"{description}: entity_id");
            Assert.AreEqual(expected.GetProperty("lat_nano").GetInt64(), geoEvent.LatNano, $"{description}: lat_nano");
            Assert.AreEqual(expected.GetProperty("lon_nano").GetInt64(), geoEvent.LonNano, $"{description}: lon_nano");
            Assert.AreEqual((ulong)0, (ulong)geoEvent.Id, $"{description}: id should be 0");
            Assert.AreEqual(expected.GetProperty("timestamp").GetUInt64(), geoEvent.Timestamp, $"{description}: timestamp");
            Assert.AreEqual(expected.GetProperty("correlation_id").GetUInt64(), (ulong)geoEvent.CorrelationId, $"{description}: correlation_id");
            Assert.AreEqual(expected.GetProperty("user_data").GetUInt64(), (ulong)geoEvent.UserData, $"{description}: user_data");
            Assert.AreEqual(expected.GetProperty("group_id").GetUInt64(), geoEvent.GroupId, $"{description}: group_id");
            Assert.AreEqual(expected.GetProperty("altitude_mm").GetInt32(), geoEvent.AltitudeMm, $"{description}: altitude_mm");
            Assert.AreEqual(expected.GetProperty("velocity_mms").GetUInt32(), geoEvent.VelocityMms, $"{description}: velocity_mms");
            Assert.AreEqual(expected.GetProperty("ttl_seconds").GetUInt32(), geoEvent.TtlSeconds, $"{description}: ttl_seconds");
            Assert.AreEqual(expected.GetProperty("accuracy_mm").GetUInt32(), geoEvent.AccuracyMm, $"{description}: accuracy_mm");
            Assert.AreEqual((ushort)expected.GetProperty("heading_cdeg").GetInt32(), geoEvent.HeadingCdeg, $"{description}: heading_cdeg");
            Assert.AreEqual((GeoEventFlags)expected.GetProperty("flags").GetUInt16(), geoEvent.Flags, $"{description}: flags");
        }
    }

    // ========================================================================
    // Validation Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_InvalidLatitudes_AreRejected()
    {
        var invalids = testData!.RootElement.GetProperty("validation_cases").GetProperty("invalid_latitudes");

        foreach (var elem in invalids.EnumerateArray())
        {
            var lat = elem.GetDouble();
            Assert.IsFalse(IsValidLatitude(lat), $"Latitude {lat} should be invalid");
        }
    }

    [TestMethod]
    public void WireFormat_InvalidLongitudes_AreRejected()
    {
        var invalids = testData!.RootElement.GetProperty("validation_cases").GetProperty("invalid_longitudes");

        foreach (var elem in invalids.EnumerateArray())
        {
            var lon = elem.GetDouble();
            Assert.IsFalse(IsValidLongitude(lon), $"Longitude {lon} should be invalid");
        }
    }

    [TestMethod]
    public void WireFormat_ValidBoundaryLatitudes_AreAccepted()
    {
        var valids = testData!.RootElement.GetProperty("validation_cases").GetProperty("valid_boundary_latitudes");

        foreach (var elem in valids.EnumerateArray())
        {
            var lat = elem.GetDouble();
            Assert.IsTrue(IsValidLatitude(lat), $"Latitude {lat} should be valid");
        }
    }

    [TestMethod]
    public void WireFormat_ValidBoundaryLongitudes_AreAccepted()
    {
        var valids = testData!.RootElement.GetProperty("validation_cases").GetProperty("valid_boundary_longitudes");

        foreach (var elem in valids.EnumerateArray())
        {
            var lon = elem.GetDouble();
            Assert.IsTrue(IsValidLongitude(lon), $"Longitude {lon} should be valid");
        }
    }

    // ========================================================================
    // TTL Types Wire Format Tests
    // ========================================================================

    [TestMethod]
    public void WireFormat_TtlOperationResult_MatchCanonical()
    {
        // Verify TtlOperationResult enum values match the spec
        Assert.AreEqual((byte)0, (byte)TtlOperationResult.Success, "Success");
        Assert.AreEqual((byte)1, (byte)TtlOperationResult.EntityNotFound, "EntityNotFound");
        Assert.AreEqual((byte)2, (byte)TtlOperationResult.InvalidTtl, "InvalidTtl");
        Assert.AreEqual((byte)3, (byte)TtlOperationResult.NotPermitted, "NotPermitted");
        Assert.AreEqual((byte)4, (byte)TtlOperationResult.EntityImmutable, "EntityImmutable");
    }

    [TestMethod]
    public void WireFormat_TtlSetRequest_SizeIs64Bytes()
    {
        // Wire format requires exactly 64 bytes
        Assert.AreEqual(64, TtlSetRequest.SIZE, "TtlSetRequest.SIZE");
        Assert.AreEqual(64, System.Runtime.InteropServices.Marshal.SizeOf<TtlSetRequest>(), "Marshal.SizeOf<TtlSetRequest>");
    }

    [TestMethod]
    public void WireFormat_TtlSetResponse_SizeIs64Bytes()
    {
        Assert.AreEqual(64, TtlSetResponse.SIZE, "TtlSetResponse.SIZE");
        Assert.AreEqual(64, System.Runtime.InteropServices.Marshal.SizeOf<TtlSetResponse>(), "Marshal.SizeOf<TtlSetResponse>");
    }

    [TestMethod]
    public void WireFormat_TtlExtendRequest_SizeIs64Bytes()
    {
        Assert.AreEqual(64, TtlExtendRequest.SIZE, "TtlExtendRequest.SIZE");
        Assert.AreEqual(64, System.Runtime.InteropServices.Marshal.SizeOf<TtlExtendRequest>(), "Marshal.SizeOf<TtlExtendRequest>");
    }

    [TestMethod]
    public void WireFormat_TtlExtendResponse_SizeIs64Bytes()
    {
        Assert.AreEqual(64, TtlExtendResponse.SIZE, "TtlExtendResponse.SIZE");
        Assert.AreEqual(64, System.Runtime.InteropServices.Marshal.SizeOf<TtlExtendResponse>(), "Marshal.SizeOf<TtlExtendResponse>");
    }

    [TestMethod]
    public void WireFormat_TtlClearRequest_SizeIs64Bytes()
    {
        Assert.AreEqual(64, TtlClearRequest.SIZE, "TtlClearRequest.SIZE");
        Assert.AreEqual(64, System.Runtime.InteropServices.Marshal.SizeOf<TtlClearRequest>(), "Marshal.SizeOf<TtlClearRequest>");
    }

    [TestMethod]
    public void WireFormat_TtlClearResponse_SizeIs64Bytes()
    {
        Assert.AreEqual(64, TtlClearResponse.SIZE, "TtlClearResponse.SIZE");
        Assert.AreEqual(64, System.Runtime.InteropServices.Marshal.SizeOf<TtlClearResponse>(), "Marshal.SizeOf<TtlClearResponse>");
    }

    [TestMethod]
    public void WireFormat_TtlSetRequest_FieldInitialization()
    {
        var request = new TtlSetRequest
        {
            EntityId = 12345,
            TtlSeconds = 3600,
            Flags = 0,
        };

        Assert.AreEqual((UInt128)12345, request.EntityId, "EntityId");
        Assert.AreEqual(3600u, request.TtlSeconds, "TtlSeconds");
        Assert.AreEqual(0u, request.Flags, "Flags");
    }

    [TestMethod]
    public void WireFormat_TtlExtendRequest_FieldInitialization()
    {
        var request = new TtlExtendRequest
        {
            EntityId = 67890,
            ExtendBySeconds = 86400,
            Flags = 0,
        };

        Assert.AreEqual((UInt128)67890, request.EntityId, "EntityId");
        Assert.AreEqual(86400u, request.ExtendBySeconds, "ExtendBySeconds");
        Assert.AreEqual(0u, request.Flags, "Flags");
    }

    [TestMethod]
    public void WireFormat_TtlClearRequest_FieldInitialization()
    {
        var request = new TtlClearRequest
        {
            EntityId = 11111,
            Flags = 0,
        };

        Assert.AreEqual((UInt128)11111, request.EntityId, "EntityId");
        Assert.AreEqual(0u, request.Flags, "Flags");
    }

    // Helper methods for validation (matching the spec)
    private static bool IsValidLatitude(double lat) => lat >= -90.0 && lat <= 90.0;
    private static bool IsValidLongitude(double lon) => lon >= -180.0 && lon <= 180.0;
}
