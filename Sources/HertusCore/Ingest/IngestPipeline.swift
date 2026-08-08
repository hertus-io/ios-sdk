import Foundation

/// Queued events, batched, sent, and retried.
///
/// Owns the queue and the uploader and nothing else. It is the only thing that
/// knows a batch is a unit of retry, and it is deliberately the only place a
/// decision about giving up is made.
///
/// Runs on the SDK's serial queue. One upload is in flight at a time, because a
/// second concurrent batch would be the same events again: the queue is peeked
/// rather than taken, so nothing is removed until the server has it.
public final class IngestPipeline {

    /// Fifty events is a payload of a few kilobytes, which is one round trip on
    /// a bad network rather than several.
    public static let defaultBatchSize = 50

    private let queue: EventQueue
    private let uploader: IngestUploader
    private let log: Logger
    private let delay: BootstrapSequence.DelayScheduler
    private let maxBatchSize: Int

    private var batchSize: Int
    private var evidence: GuardEvidence?
    private var sending = false
    private var attempt = 0
    private var stopped = false

    public init(
        queue: EventQueue,
        uploader: IngestUploader,
        log: Logger,
        delay: @escaping BootstrapSequence.DelayScheduler,
        maxBatchSize: Int = IngestPipeline.defaultBatchSize
    ) {
        self.queue = queue
        self.uploader = uploader
        self.log = log
        self.delay = delay
        self.maxBatchSize = maxBatchSize
        self.batchSize = maxBatchSize
    }

    /// How many events are waiting. For diagnostics and for tests.
    public var pending: Int { queue.count }

    /// Whether the pipeline has given up for this process.
    public var isStopped: Bool { stopped }

    /// Guard's answer for this launch, forwarded with every batch.
    ///
    /// Set once startup settles. Batches sent before it arrives carry no
    /// evidence, which is correct rather than unfortunate: they genuinely
    /// happened before the device was identified.
    public func setEvidence(_ evidence: GuardEvidence?) {
        self.evidence = evidence
    }

    /// Queues one event and sends when there is enough to be worth a request.
    ///
    /// Sending on every event would mean one request per tap on a busy screen.
    /// Sending only on a timer would mean an event raised just before the app is
    /// killed is lost. A batch-sized threshold plus `flush` covers both without
    /// a timer to get wrong.
    public func track(_ envelope: String) {
        guard !stopped else { return }

        queue.append(envelope)

        if queue.count >= batchSize {
            send()
        }
    }

    /// Asks the pipeline to upload what it is holding.
    ///
    /// Advisory. The SDK decides when it actually goes: a flush during a failing
    /// retry does not start a second upload, it lets the one in flight finish.
    public func flush() {
        guard !stopped, !queue.isEmpty else { return }
        attempt = 0
        send()
    }

    /// Stops for the process lifetime and throws away what is queued.
    ///
    /// For the one case that warrants it: the server said this app's token is
    /// not ours. Holding events for a token that will never be accepted is a
    /// queue that only ever grows.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        queue.clear()
    }

    // MARK: sending

    private func send() {
        guard !sending, !stopped, !queue.isEmpty else { return }

        let batch = queue.peek(batchSize)
        guard !batch.isEmpty else { return }

        sending = true
        uploader.send(payloads: batch, evidence: evidence) { [weak self] outcome in
            self?.handle(outcome, sent: batch.count)
        }
    }

    private func handle(_ outcome: IngestOutcome, sent: Int) {
        sending = false

        switch outcome {
        case .accepted:
            queue.removeFirst(sent)
            attempt = 0
            log.d("ingest accepted \(sent) event(s); \(queue.count) left")

            // Straight on to the next batch while the network is working. A
            // device that has been offline for a day has a queue to clear and no
            // reason to clear it one launch at a time.
            if !queue.isEmpty {
                send()
            }

        case .refused(let status):
            // Retrying a payload the server has already refused to parse is how
            // one bad event blocks a queue forever.
            queue.removeFirst(sent)
            attempt = 0
            log.w("ingest refused \(sent) event(s) with \(status); dropping them and continuing")
            if !queue.isEmpty {
                send()
            }

        case .rejected(let status):
            log.e(
                "ingest \(status): this app token was rejected. Nothing further will be sent. "
                    + "Check the key in Developer tools -> SDK credentials, and that the app is "
                    + "not archived."
            )
            stop()

        case .tooLarge:
            // Halve and try the same events again. One event that is still too
            // large is a poison pill, and is dropped rather than retried
            // forever.
            if batchSize > 1 {
                batchSize = max(1, batchSize / 2)
                log.w("ingest batch was too large; halving to \(batchSize)")
                send()
            } else {
                queue.removeFirst(1)
                log.w("a single event was too large to send; dropping it")
                send()
            }

        case .unavailable(let reason, let retryAfterSeconds):
            attempt += 1
            guard attempt < Backoff.maxAttempts else {
                log.w(
                    "ingest gave up after \(attempt) attempts (\(reason)); "
                        + "\(queue.count) event(s) stay queued for the next launch"
                )
                attempt = 0
                return
            }

            log.d("ingest unavailable (\(reason)); retrying")
            delay(Backoff.delayMillis(attempt: attempt, retryAfterSeconds: retryAfterSeconds)) {
                [weak self] in self?.send()
            }
        }
    }
}
