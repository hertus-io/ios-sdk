import Foundation

/// Where the SDK is in its life.
///
/// `degraded` is the one worth understanding: a fully functional SDK with Guard
/// switched off, reached when configuration could not be obtained. It is not a
/// stopped state. It accepts every call and keeps trying to leave.
///
/// `disabled` is terminal for the process. It means the server said no, and no
/// amount of asking again will change that.
public enum SdkState: CaseIterable {
    case idle
    case initializing
    case ready
    case degraded
    case disabled

    /// Whether work handed in now should run rather than queue or be dropped.
    public var acceptsWork: Bool { self == .ready || self == .degraded }

    /// Whether work handed in now should be held until startup settles.
    public var queuesWork: Bool { self == .initializing }

    public var isTerminal: Bool { self == .disabled }
}

/// Holds the current `SdkState` and refuses transitions that are not in the
/// design.
///
/// A separate type rather than a stored property because the legal moves are a
/// rule worth stating once and testing directly. The alternative is five
/// assignments spread across a startup path, where a wrong one shows up as an
/// SDK still answering calls after the server told it to stop.
///
/// Reads are lock-free. Writes happen on the SDK's single serial queue, apart
/// from the one at `Hertus.initialize`.
public final class SdkStateHolder {

    private let lock = NSLock()
    private var state: SdkState = .idle

    public init() {}

    public var current: SdkState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Moves to `next` if the transition is legal, and reports whether it
    /// happened.
    ///
    /// Returns false rather than throwing, because the caller is a startup path
    /// that must not crash a host app. A refused transition means something
    /// already settled the SDK, which is a race the design tolerates: the first
    /// outcome wins.
    @discardableResult
    public func move(to next: SdkState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard SdkStateHolder.canMove(from: state, to: next) else { return false }
        state = next
        return true
    }

    public func canMove(to next: SdkState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return SdkStateHolder.canMove(from: state, to: next)
    }

    static func canMove(from current: SdkState, to next: SdkState) -> Bool {
        switch current {
        // A malformed token disables the SDK before any work is scheduled,
        // which is why idle reaches disabled without passing through
        // initializing.
        case .idle:
            return next == .initializing || next == .disabled

        case .initializing:
            return next == .ready || next == .degraded || next == .disabled

        // Degraded is not a dead end. A retry that succeeds behind it upgrades
        // the SDK in place, which is the whole reason the state exists.
        case .degraded:
            return next == .ready || next == .disabled

        case .ready:
            return next == .disabled

        case .disabled:
            return false
        }
    }
}
