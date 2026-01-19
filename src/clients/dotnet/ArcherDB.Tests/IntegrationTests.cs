using Microsoft.VisualStudio.TestTools.UnitTesting;
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace ArcherDB.Tests;

[TestClass]
public class IntegrationTests
{
    private static TBServer server = null!;
    private static GeoClient client = null!;

    [ClassInitialize]
    public static void Initialize(TestContext _)
    {
        server = new TBServer();
        client = new GeoClient(0, new string[] { server.Address });
    }

    [ClassCleanup]
    public static void Cleanup()
    {
        client.Dispose();
        server.Dispose();
    }

    [TestMethod]
    [ExpectedException(typeof(ArgumentNullException))]
    public void ConstructorWithNullReplicaAddresses()
    {
        string[]? addresses = null;
        _ = new GeoClient(0, addresses!);
    }

    [TestMethod]
    public void ConstructorWithNullReplicaAddressElement()
    {
        try
        {
            var addresses = new string[] { "3000", null! };
            _ = new GeoClient(0, addresses);
            Assert.Fail();
        }
        catch (InitializationException exception)
        {
            Assert.AreEqual(InitializationStatus.AddressInvalid, exception.Status);
        }
    }

    [TestMethod]
    public void ConstructorWithEmptyReplicaAddresses()
    {
        try
        {
            _ = new GeoClient(0, Array.Empty<string>());
            Assert.Fail();
        }
        catch (InitializationException exception)
        {
            Assert.AreEqual(InitializationStatus.AddressInvalid, exception.Status);
        }
    }

    [TestMethod]
    public void ConstructorWithEmptyReplicaAddressElement()
    {
        try
        {
            _ = new GeoClient(0, new string[] { "" });
            Assert.Fail();
        }
        catch (InitializationException exception)
        {
            Assert.AreEqual(InitializationStatus.AddressInvalid, exception.Status);
        }
    }

    [TestMethod]
    public void ConstructorWithInvalidReplicaAddresses()
    {
        try
        {
            var addresses = Enumerable.Range(3000, 3100).Select(x => x.ToString()).ToArray();
            _ = new GeoClient(0, addresses);
            Assert.Fail();
        }
        catch (InitializationException exception)
        {
            Assert.AreEqual(InitializationStatus.AddressLimitExceeded, exception.Status);
        }
    }

    [TestMethod]
    public void ConstructorAndFinalizer()
    {
        // No using here, we want to test the finalizer
        var client = new GeoClient(1, new string[] { "3000" });
        Assert.IsTrue(client.ClusterID == 1);
    }

    [TestMethod]
    public void InsertEventAndQueryByUuid()
    {
        var entityId = ID.Create();
        var geoEvent = CreateGeoEvent(entityId, 37_774_900_000L, -122_419_400_000L);

        var insertResult = client.InsertEvent(geoEvent);
        Assert.AreEqual(InsertGeoEventResult.Ok, insertResult);

        var results = client.QueryByUuid(new QueryUuidFilter { EntityId = entityId });
        Assert.AreEqual(1, results.Length);
        Assert.AreEqual(entityId, results[0].EntityId);
        Assert.AreNotEqual(UInt128.Zero, results[0].Id);
    }

    [TestMethod]
    public void QueryByUuidBatchReportsMissing()
    {
        var entityId1 = ID.Create();
        var entityId2 = ID.Create();
        var missingId = ID.Create();

        var batch = new[]
        {
            CreateGeoEvent(entityId1, 37_774_900_000L, -122_419_400_000L),
            CreateGeoEvent(entityId2, 37_775_900_000L, -122_418_400_000L),
        };

        var insertResults = client.InsertEvents(batch);
        Assert.IsTrue(insertResults.All(result => result.Result == InsertGeoEventResult.Ok));

        var lookup = client.QueryByUuidBatch(new[] { entityId1, missingId, entityId2 });
        Assert.AreEqual(2U, lookup.FoundCount);
        Assert.AreEqual(1U, lookup.NotFoundCount);
        Assert.IsTrue(lookup.NotFoundIndices.Contains((ushort)1));

        var foundIds = lookup.Events.Select(e => e.EntityId).ToArray();
        Assert.IsTrue(foundIds.Contains(entityId1));
        Assert.IsTrue(foundIds.Contains(entityId2));
    }

    [TestMethod]
    public void QueryByRadiusFindsNearby()
    {
        var entityId = ID.Create();
        var lat = 37_774_900_000L;
        var lon = -122_419_400_000L;

        var insertResult = client.InsertEvent(CreateGeoEvent(entityId, lat, lon));
        Assert.AreEqual(InsertGeoEventResult.Ok, insertResult);

        var filter = new QueryRadiusFilter
        {
            CenterLatNano = lat,
            CenterLonNano = lon,
            RadiusMm = 1_000_000,
            Limit = 10,
            TimestampMin = 0,
            TimestampMax = 0,
            GroupId = 0,
        };

        var results = client.QueryByRadius(filter);
        Assert.IsTrue(results.Any(e => e.EntityId == entityId));
    }

    [TestMethod]
    public void DeleteEntityRemovesLookup()
    {
        var entityId = ID.Create();
        var insertResult = client.InsertEvent(CreateGeoEvent(entityId, 40_712_800_000L, -74_006_000_000L));
        Assert.AreEqual(InsertGeoEventResult.Ok, insertResult);

        var deleteResult = client.DeleteEntity(entityId);
        Assert.AreEqual(DeleteEntityResult.Ok, deleteResult);

        var results = client.QueryByUuid(new QueryUuidFilter { EntityId = entityId });
        Assert.AreEqual(0, results.Length);
    }

    private static GeoEvent CreateGeoEvent(UInt128 entityId, long latNano, long lonNano)
    {
        return new GeoEvent
        {
            Id = 0,
            EntityId = entityId,
            CorrelationId = 0,
            UserData = 0,
            LatNano = latNano,
            LonNano = lonNano,
            GroupId = 0,
            Timestamp = 0,
            AltitudeMm = 0,
            VelocityMms = 0,
            TtlSeconds = 0,
            AccuracyMm = 0,
            HeadingCdeg = 0,
            Flags = GeoEventFlags.None,
        };
    }
}

internal class TBServer : IDisposable
{
    // Path relative from /ArcherDB.Test/bin/<framework>/<release>/<platform> :
    private const string PROJECT_ROOT = "../../../../..";
    private const string ARCH_PATH = PROJECT_ROOT + "/../../../zig-out/bin";
    private const string ARCH_EXE = "archerdb";
    private const string ARCH_SERVER = ARCH_PATH + "/" + ARCH_EXE;

    private readonly Process process;
    private readonly string dataFile;

    public string Address { get; }

    public TBServer()
    {
        dataFile = Path.GetRandomFileName();

        {
            using var format = new Process();
            format.StartInfo.FileName = ARCH_SERVER;
            format.StartInfo.Arguments = $"format --cluster=0 --replica=0 --replica-count=1 --development ./{dataFile}";
            format.StartInfo.RedirectStandardError = true;
            format.Start();
            var formatStderr = format.StandardError.ReadToEnd();
            format.WaitForExit();
            if (format.ExitCode != 0) throw new InvalidOperationException($"format failed, ExitCode={format.ExitCode} stderr:\n{formatStderr}");
        }

        process = new Process();
        process.StartInfo.FileName = ARCH_SERVER;
        process.StartInfo.Arguments = $"start --addresses=0 --development ./{dataFile}";
        process.StartInfo.RedirectStandardInput = true;
        process.StartInfo.RedirectStandardOutput = true;
        process.Start();

        Address = process.StandardOutput.ReadLine()!.Trim();
    }

    public void Dispose()
    {
        process.Kill();
        process.WaitForExit();
        process.Dispose();
        File.Delete($"./{dataFile}");
    }
}
