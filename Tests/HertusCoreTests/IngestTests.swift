import XCTest
@testable import HertusCore

private func quietLog() -> Logger {
    Logger(level: .suppress, environment: .sandbox) { _, _ in }
}

// MARK: the queue

final class EventQueueTests: XCTestCase {

    private var store = InMemoryEventStore()

    override func setUp() {
        super.setUp()
        store = InMemoryEventStore()
    }

    private func makeQueue(capacity: Int = EventQueue.defaultCapacity) -> EventQueue {
        EventQueue(capacity: capacity, store: store, log: quietLog())
    }

    func testEventsComeBackInTheOrderTheyArrived() {
        let queue = makeQueue()
        queue.append("a")
        queue.append("b")
        queue.append("c")

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.peek(2), ["a", "b"])
    }

    /// Peek rather than take, so a batch that fails stays queued without a
    /// window in which a crash loses it.
    func testPeekDoesNotRemove() {
        let queue = makeQueue()
        queue.append("a")

        XCTAssertEqual(queue.peek(10), ["a"])
        XCTAssertEqual(queue.peek(10), ["a"])
        XCTAssertEqual(queue.count, 1)
    }

    func testRemovingTakesFromTheFront() {
        let queue = makeQueue()
        ["a", "b", "c"].forEach(queue.append)
        queue.removeFirst(2)

        XCTAssertEqual(queue.peek(10), ["c"])
    }

    func testRemovingMoreThanIsHeldIsHarmless() {
        let queue = makeQueue()
        queue.append("a")
        queue.removeFirst(99)

        XCTAssertTrue(queue.isEmpty)
    }

    /// A full queue means something is wrong, and the recent events describe
    /// what is happening now while the old ones describe a launch that already
    /// failed.
    func testTheQueueIsBoundedAndDropsTheOldest() {
        let queue = makeQueue(capacity: 3)
        ["a", "b", "c", "d", "e"].forEach(queue.append)

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.peek(3), ["c", "d", "e"])
    }

    /// The ordinary way a mobile app ends is being killed. An in-memory queue
    /// loses exactly the sessions that ended badly.
    func testTheQueueSurvivesBeingRebuilt() {
        let first = makeQueue()
        first.append("a")
        first.append("b")

        let second = makeQueue()
        XCTAssertEqual(second.peek(10), ["a", "b"])
    }

    /// A capacity that shrank between versions would otherwise leave a queue
    /// permanently over its limit.
    func testARecoveredQueueIsTrimmedToTheCurrentCapacity() {
        let first = makeQueue(capacity: 10)
        (0..<10).forEach { first.append("e\($0)") }

        let second = makeQueue(capacity: 3)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(second.peek(3), ["e7", "e8", "e9"])
    }

    func testEveryChangeIsPersistedRatherThanOnlyTheLast() {
        let queue = makeQueue()
        queue.append("a")
        XCTAssertEqual(store.load(), ["a"])

        queue.removeFirst(1)
        XCTAssertEqual(store.load(), [])
    }

    func testClearEmptiesBothTheQueueAndTheStore() {
        let queue = makeQueue()
        ["a", "b"].forEach(queue.append)
        queue.clear()

        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(store.load(), [])
    }
}

// MARK: the pipeline

final class IngestPipelineTests: XCTestCase {

    /// Answers the scripted outcomes in order, then repeats the last forever.
    final class ScriptedUploader: IngestUploader {
        private var remaining: [IngestOutcome]
        private var last: IngestOutcome

        private(set) var batches: [[String]] = []
        private(set) var evidenceSeen: [GuardEvidence?] = []
        var calls: Int { batches.count }

        init(_ outcomes: IngestOutcome...) {
            remaining = outcomes
            last = outcomes[outcomes.count - 1]
        }

        func send(
            payloads: [String],
            evidence: GuardEvidence?,
            completion: @escaping (IngestOutcome) -> Void
        ) {
            batches.append(payloads)
            evidenceSeen.append(evidence)
            if !remaining.isEmpty {
                last = remaining.removeFirst()
            }
            completion(last)
        }
    }

    private var store = InMemoryEventStore()
    private var delays: [Int64] = []

    override func setUp() {
        super.setUp()
        store = InMemoryEventStore()
        delays = []
    }

    private func makePipeline(
        _ uploader: IngestUploader,
        batchSize: Int = 3,
        capacity: Int = EventQueue.defaultCapacity
    ) -> IngestPipeline {
        IngestPipeline(
            queue: EventQueue(capacity: capacity, store: store, log: quietLog()),
            uploader: uploader,
            log: quietLog(),
            delay: { [self] delayMs, work in
                delays.append(delayMs)
                work()
            },
            maxBatchSize: batchSize
        )
    }

    /// One request per tap on a busy screen is the thing batching exists to
    /// avoid.
    func testNothingIsSentUntilABatchIsWorthSending() {
        let uploader = ScriptedUploader(.accepted)
        let pipeline = makePipeline(uploader, batchSize: 3)

        pipeline.track("a")
        pipeline.track("b")

        XCTAssertEqual(uploader.calls, 0)
        XCTAssertEqual(pipeline.pending, 2)
    }

    func testAFullBatchGoesOnItsOwn() {
        let uploader = ScriptedUploader(.accepted)
        let pipeline = makePipeline(uploader, batchSize: 3)

        ["a", "b", "c"].forEach(pipeline.track)

        XCTAssertEqual(uploader.batches, [["a", "b", "c"]])
        XCTAssertEqual(pipeline.pending, 0)
    }

    func testFlushSendsWhatIsHeldWhateverTheSize() {
        let uploader = ScriptedUploader(.accepted)
        let pipeline = makePipeline(uploader, batchSize: 10)

        pipeline.track("a")
        pipeline.flush()

        XCTAssertEqual(uploader.batches, [["a"]])
        XCTAssertEqual(pipeline.pending, 0)
    }

    func testFlushOnAnEmptyQueueDoesNothing() {
        let uploader = ScriptedUploader(.accepted)
        makePipeline(uploader).flush()

        XCTAssertEqual(uploader.calls, 0)
    }

    /// A device offline for a day has a queue to clear and no reason to clear it
    /// one launch at a time.
    func testItKeepsGoingWhileTheNetworkIsWorking() {
        let uploader = ScriptedUploader(.accepted)
        let pipeline = makePipeline(uploader, batchSize: 2)

        ["a", "b", "c", "d", "e"].forEach(pipeline.track)
        pipeline.flush()

        XCTAssertEqual(uploader.batches, [["a", "b"], ["c", "d"], ["e"]])
        XCTAssertEqual(pipeline.pending, 0)
    }

    /// Nothing is removed until the server has it.
    func testAFailedBatchStaysQueued() {
        let uploader = ScriptedUploader(.unavailable(reason: "dns"))
        let pipeline = makePipeline(uploader, batchSize: 2)

        pipeline.track("a")
        pipeline.track("b")

        XCTAssertEqual(pipeline.pending, 2)
        XCTAssertEqual(store.load(), ["a", "b"])
    }

    func testAnUnavailableServerRetriesWithBackoffThenStopsForThisLaunch() {
        let uploader = ScriptedUploader(.unavailable(reason: "timeout"))
        let pipeline = makePipeline(uploader, batchSize: 1)

        pipeline.track("a")

        XCTAssertEqual(uploader.calls, Backoff.maxAttempts)
        XCTAssertEqual(delays.count, Backoff.maxAttempts - 1)
        XCTAssertEqual(pipeline.pending, 1, "the event survives for the next launch")
        XCTAssertFalse(pipeline.isStopped)
    }

    func testALaterSuccessClearsTheQueue() {
        let uploader = ScriptedUploader(
            .unavailable(reason: "timeout"),
            .unavailable(reason: "timeout"),
            .accepted
        )
        let pipeline = makePipeline(uploader, batchSize: 1)

        pipeline.track("a")

        XCTAssertEqual(pipeline.pending, 0)
        XCTAssertEqual(uploader.calls, 3)
    }

    func testTheServersOwnRetryAfterIsHonoured() {
        let uploader = ScriptedUploader(
            .unavailable(reason: "rate limited", retryAfterSeconds: 9),
            .accepted
        )
        let pipeline = makePipeline(uploader, batchSize: 1)

        pipeline.track("a")

        XCTAssertEqual(delays, [9_000])
    }

    /// Retrying a payload the server has already refused to parse is how one bad
    /// event blocks a queue forever.
    func testARefusedBatchIsDroppedRatherThanRetried() {
        let uploader = ScriptedUploader(.refused(status: 400), .accepted)
        let pipeline = makePipeline(uploader, batchSize: 2)

        ["a", "b", "c"].forEach(pipeline.track)
        pipeline.flush()

        XCTAssertEqual(pipeline.pending, 0)
        XCTAssertFalse(pipeline.isStopped, "one bad batch is not a reason to stop measuring")
    }

    func testATooLargeBatchIsHalvedAndRetried() {
        let uploader = ScriptedUploader(.tooLarge, .accepted)
        let pipeline = makePipeline(uploader, batchSize: 4)

        ["a", "b", "c", "d"].forEach(pipeline.track)

        XCTAssertEqual(uploader.batches.first?.count, 4)
        XCTAssertEqual(uploader.batches.dropFirst().first?.count, 2, "halved after the refusal")
        XCTAssertEqual(pipeline.pending, 0)
    }

    /// A single event that is still too large is a poison pill.
    func testASingleOversizeEventIsDroppedRatherThanRetriedForever() {
        let uploader = ScriptedUploader(.tooLarge)
        let pipeline = makePipeline(uploader, batchSize: 1)

        pipeline.track("enormous")

        XCTAssertEqual(pipeline.pending, 0)
    }

    /// Holding events for a token that will never be accepted is a queue that
    /// only ever grows.
    func testARejectionStopsEverythingAndEmptiesTheQueue() {
        let uploader = ScriptedUploader(.rejected(status: 401))
        let pipeline = makePipeline(uploader, batchSize: 1)

        pipeline.track("a")

        XCTAssertTrue(pipeline.isStopped)
        XCTAssertEqual(pipeline.pending, 0)
        XCTAssertEqual(store.load(), [])

        pipeline.track("b")
        XCTAssertEqual(pipeline.pending, 0, "a stopped pipeline accepts nothing further")
        XCTAssertEqual(uploader.calls, 1)
    }

    /// Identification happens once per launch, so copying it onto every event
    /// would multiply a bearer token by the event count.
    func testEvidenceIsAttachedToEveryBatchOnceItIsKnown() {
        let uploader = ScriptedUploader(.accepted)
        let pipeline = makePipeline(uploader, batchSize: 1)

        pipeline.track("before")
        pipeline.setEvidence(GuardEvidence(sealedPayload: "sealed", requestId: "req", confidence: 0.9))
        pipeline.track("after")

        XCTAssertNil(uploader.evidenceSeen[0], "batches sent before identification carry none")
        XCTAssertEqual(uploader.evidenceSeen[1]?.sealedPayload, "sealed")
    }

    func testEvidenceIsAbsentWhenGuardIdentifiedNothing() {
        XCTAssertNil(GuardEvidence(signal: nil))
        XCTAssertNil(GuardEvidence(signal: GuardSignal.disabled()))
        XCTAssertNil(GuardEvidence(signal: GuardSignal.none()))

        let identified = GuardSignal(
            sealedPayload: "sealed",
            requestId: "req",
            confidence: 0.5,
            source: .engine
        )
        XCTAssertEqual(GuardEvidence(signal: identified)?.requestId, "req")
    }
}

// MARK: response mapping

final class IngestOutcomeTests: XCTestCase {

    private func outcome(_ status: Int, retryAfter: String? = nil) -> IngestOutcome {
        IngestClient.outcome(status: status, retryAfter: retryAfter)
    }

    func testAcceptedCoversBothSuccessCodes() {
        XCTAssertEqual(outcome(200), .accepted)
        XCTAssertEqual(outcome(202), .accepted)
    }

    func testTheTerminalCodesMatchBootstrap() {
        XCTAssertEqual(outcome(401), .rejected(status: 401))
        XCTAssertEqual(outcome(403), .rejected(status: 403))
    }

    func testAMalformedBatchIsRefusedRatherThanRetried() {
        XCTAssertEqual(outcome(400), .refused(status: 400))
    }

    func testAnOversizeBatchAsksForHalving() {
        XCTAssertEqual(outcome(413), .tooLarge)
    }

    func testRateLimitingCarriesRetryAfter() {
        XCTAssertEqual(
            outcome(429, retryAfter: "12"),
            .unavailable(reason: "rate limited", retryAfterSeconds: 12)
        )
        XCTAssertEqual(
            outcome(429),
            .unavailable(reason: "rate limited", retryAfterSeconds: nil)
        )
    }

    func testEverythingElseIsWorthAnotherAttempt() {
        XCTAssertEqual(outcome(500), .unavailable(reason: "server returned 500"))
        XCTAssertEqual(outcome(503), .unavailable(reason: "server returned 503"))
    }
}
