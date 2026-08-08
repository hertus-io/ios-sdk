import Foundation

/// Everything the SDK says back to the host app.
///
/// One place, for two reasons that each cost a bug elsewhere. Callbacks reach
/// the main queue, because a host app updating its UI from one should not have
/// to know which queue the SDK used. And `announceInitialized` fires exactly
/// once, because "initialization finished" is a fact about a launch rather than
/// about a code path, and several paths reach it.
///
/// The delivery function is injected so a test can run callbacks inline instead
/// of pumping a run loop.
public final class CallbackDispatcher {

    /// How a callback reaches the host app. Defaults to the main queue.
    public typealias Deliver = (@escaping () -> Void) -> Void

    private let onInitialized: HertusInitHandler?
    private let onError: HertusErrorHandler?
    private let onGuardSignal: HertusGuardHandler?
    private let deliver: Deliver

    private let lock = NSLock()
    private var announced = false

    public init(
        onInitialized: HertusInitHandler?,
        onError: HertusErrorHandler?,
        onGuardSignal: HertusGuardHandler?,
        deliver: @escaping Deliver = { work in DispatchQueue.main.async(execute: work) }
    ) {
        self.onInitialized = onInitialized
        self.onError = onError
        self.onGuardSignal = onGuardSignal
        self.deliver = deliver
    }

    /// Whether `announceInitialized` has already fired for this launch.
    public var hasAnnounced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return announced
    }

    /// Reports that startup settled, successfully or not. Subsequent calls do
    /// nothing.
    ///
    /// - Parameter ready: true when Guard is running. False covers both a
    ///   degraded SDK and a disabled one; the difference is in the log and in
    ///   `deliverError`, because a host app almost never branches on it and the
    ///   ones that do want the code rather than a boolean.
    public func announceInitialized(ready: Bool) {
        lock.lock()
        if announced {
            lock.unlock()
            return
        }
        announced = true
        lock.unlock()

        guard let onInitialized else { return }
        deliver { onInitialized(ready) }
    }

    public func deliverError(_ code: HertusErrorCode) {
        guard let onError else { return }
        deliver { onError(HertusError(code: code)) }
    }

    /// Reports one identification attempt.
    ///
    /// - Parameter identified: whether the attempt produced something the server
    ///   can resolve. False for a switched-off Guard as well as a failed one,
    ///   which is why `error` is the field a caller reads to tell them apart.
    public func deliverGuardSignal(identified: Bool, confidence: Double?, error: HertusError?) {
        guard let onGuardSignal else { return }
        deliver { onGuardSignal(identified, confidence, error) }
    }
}
