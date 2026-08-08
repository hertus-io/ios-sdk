import Foundation

/// Where queued events survive the process ending.
///
/// A protocol so the queue's rules can be tested without a filesystem, and so
/// the storage can change without the rules moving.
public protocol EventStore: AnyObject {

    /// Everything held, oldest first. Empty rather than nil when there is
    /// nothing, because "no events" and "could not read" are the same thing to
    /// a caller that can only carry on either way.
    func load() -> [String]

    /// Replaces everything held. Called on every change, because a queue that
    /// only persists on a clean shutdown loses exactly the sessions that ended
    /// badly.
    func save(_ payloads: [String])
}

/// A store that forgets when the process does.
///
/// For tests, and for a runtime built without persistence.
public final class InMemoryEventStore: EventStore {

    private var payloads: [String] = []

    public init() {}

    public func load() -> [String] { payloads }

    public func save(_ payloads: [String]) { self.payloads = payloads }
}

/// Events waiting to be sent.
///
/// Bounded, persistent, and drop-oldest. Every one of those is a decision:
///
/// - **Bounded**, because an SDK that grows without limit in somebody else's
///   process is a bug report about memory, not about measurement.
/// - **Persistent**, because the ordinary way a mobile app ends is being killed,
///   and an in-memory queue loses exactly the sessions that ended badly.
/// - **Drop-oldest**, because a full queue means something is wrong, and when it
///   is, the recent events describe what is happening now while the old ones
///   describe a launch that already failed.
///
/// Not thread safe by itself. Everything touching it runs on the SDK's serial
/// queue.
public final class EventQueue {

    /// Enough for a long offline stretch, small enough that a stuck SDK cannot
    /// grow without bound in somebody else's process.
    public static let defaultCapacity = 1_000

    private let capacity: Int
    private let store: EventStore
    private let log: Logger

    private var payloads: [String]
    private var dropped = 0
    private var warned = false

    public init(capacity: Int = EventQueue.defaultCapacity, store: EventStore, log: Logger) {
        self.capacity = capacity
        self.store = store
        self.log = log
        self.payloads = store.load()

        if !self.payloads.isEmpty {
            log.d("recovered \(self.payloads.count) event(s) from a previous launch")
        }
        // A capacity that shrank between versions would otherwise leave a queue
        // permanently over its limit.
        if self.payloads.count > capacity {
            self.payloads = Array(self.payloads.suffix(capacity))
            store.save(self.payloads)
        }
    }

    public var count: Int { payloads.count }

    public var isEmpty: Bool { payloads.isEmpty }

    /// Adds an event, evicting the oldest if full.
    ///
    /// Never fails and never throws. Dropping is logged once rather than per
    /// event, because a queue that overflows overflows thousands of times and a
    /// line each would bury everything else in the console.
    public func append(_ payload: String) {
        payloads.append(payload)

        if payloads.count > capacity {
            let overflow = payloads.count - capacity
            payloads.removeFirst(overflow)
            dropped += overflow

            if !warned {
                warned = true
                log.w(
                    "event queue full at \(capacity); dropping the oldest. "
                        + "Events are not reaching the server."
                )
            }
        }

        store.save(payloads)
    }

    /// The next batch to send, oldest first, without removing it.
    ///
    /// Peek rather than take, because a batch that fails has to stay queued and
    /// taking it first would mean putting it back, which is the same operation
    /// with a window in which a crash loses it.
    public func peek(_ limit: Int) -> [String] {
        Array(payloads.prefix(limit))
    }

    /// Removes the batch that was accepted.
    ///
    /// By count rather than by identity: the queue is append-only at the back
    /// and consumed from the front, so a prefix is the only thing a caller can
    /// have been given.
    public func removeFirst(_ count: Int) {
        guard count > 0 else { return }
        payloads.removeFirst(min(count, payloads.count))
        store.save(payloads)

        if payloads.isEmpty {
            // The next overflow is a new fact worth reporting.
            warned = false
            if dropped > 0 {
                log.d("queue drained; \(dropped) event(s) had been dropped")
                dropped = 0
            }
        }
    }

    /// Throws away everything held. Used when the server refuses this app.
    public func clear() {
        guard !payloads.isEmpty else { return }
        log.d("discarding \(payloads.count) queued event(s)")
        payloads.removeAll()
        dropped = 0
        warned = false
        store.save(payloads)
    }
}
