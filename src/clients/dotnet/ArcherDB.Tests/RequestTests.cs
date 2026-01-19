using Microsoft.VisualStudio.TestTools.UnitTesting;
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace ArcherDB.Tests;

[TestClass]
public class RequestTests
{
    [TestMethod]
    [ExpectedException(typeof(AssertionException))]
    public async Task UnexpectedOperation()
    {
        var callback = new CallbackSimulator<GeoEvent, QueryLatestFilter>(
            TBOperation.QueryLatest,
            (byte)99,
            null,
            PacketStatus.Ok,
            delay: 100,
            isAsync: true
        );
        var task = callback.Run();
        Assert.IsFalse(task.IsCompleted);

        _ = await task;
        Assert.Fail();
    }

    [TestMethod]
    [ExpectedException(typeof(AssertionException))]
    public async Task InvalidSizeOperation()
    {
        var buffer = new byte[GeoEvent.SIZE + 1];
        var callback = new CallbackSimulator<GeoEvent, QueryLatestFilter>(
            TBOperation.QueryLatest,
            (byte)TBOperation.QueryLatest,
            buffer,
            PacketStatus.Ok,
            delay: 100,
            isAsync: true
        );

        var task = callback.Run();
        Assert.IsFalse(task.IsCompleted);

        _ = await task;
        Assert.Fail();
    }

    [TestMethod]
    public async Task RequestException()
    {
        foreach (var isAsync in new bool[] { true, false })
        {
            var buffer = new byte[GeoEvent.SIZE];
            var callback = new CallbackSimulator<GeoEvent, QueryLatestFilter>(
                TBOperation.QueryLatest,
                (byte)TBOperation.QueryLatest,
                buffer,
                PacketStatus.TooMuchData,
                delay: 100,
                isAsync
            );

            var task = callback.Run();
            Assert.IsFalse(task.IsCompleted);

            try
            {
                _ = await task;
                Assert.Fail();
            }
            catch (RequestException exception)
            {
                Assert.AreEqual(PacketStatus.TooMuchData, exception.Status);
            }
        }
    }

    [TestMethod]
    public async Task Success()
    {
        foreach (var isAsync in new bool[] { true, false })
        {
            var buffer = MemoryMarshal.Cast<GeoEvent, byte>(new GeoEvent[]
            {
                    new GeoEvent
                    {
                        Id = 0,
                        EntityId = 1,
                        CorrelationId = 2,
                        UserData = 3,
                        LatNano = 37_774_900_000L,
                        LonNano = -122_419_400_000L,
                        GroupId = 7,
                        Timestamp = 0,
                        Flags = GeoEventFlags.Linked,
                    }
            }).ToArray();

            var callback = new CallbackSimulator<GeoEvent, QueryLatestFilter>(
                TBOperation.QueryLatest,
                (byte)TBOperation.QueryLatest,
                buffer,
                PacketStatus.Ok,
                delay: 100,
                isAsync
            );

            var task = callback.Run();
            Assert.IsFalse(task.IsCompleted);

            var events = await task;
            Assert.IsTrue(events.Length == 1);
            Assert.AreEqual((UInt128)1, events[0].EntityId);
            Assert.AreEqual((UInt128)2, events[0].CorrelationId);
            Assert.AreEqual((UInt128)3, events[0].UserData);
            Assert.AreEqual(37_774_900_000L, events[0].LatNano);
            Assert.AreEqual(-122_419_400_000L, events[0].LonNano);
            Assert.AreEqual(7UL, events[0].GroupId);
            Assert.AreEqual(GeoEventFlags.Linked, events[0].Flags);
        }
    }

    private class CallbackSimulator<TResult, TBody>
        where TResult : unmanaged
        where TBody : unmanaged
    {
        private readonly Request<TResult, TBody> request;
        private readonly byte receivedOperation;
        private readonly Memory<byte> buffer;
        private readonly PacketStatus status;
        private readonly int delay;

        public CallbackSimulator(TBOperation operation, byte receivedOperation, Memory<byte> buffer, PacketStatus status, int delay, bool isAsync)
        {
            unsafe
            {
                this.request = isAsync ? new AsyncRequest<TResult, TBody>(operation) : new BlockingRequest<TResult, TBody>(operation);
                this.receivedOperation = receivedOperation;
                this.buffer = buffer;
                this.status = status;
                this.delay = delay;
            }
        }

        public Task<TResult[]> Run()
        {
            Task.Run(() =>
            {
                unsafe
                {
                    Task.Delay(delay).Wait();
                    request.Complete(status, receivedOperation, buffer.Span);
                }
            });

            if (request is AsyncRequest<TResult, TBody> asyncRequest)
            {
                return asyncRequest.Wait();
            }
            else if (request is BlockingRequest<TResult, TBody> blockingRequest)
            {
                return Task.Run(() => blockingRequest.Wait());
            }
            else
            {
                throw new NotImplementedException();
            }
        }
    }

}
