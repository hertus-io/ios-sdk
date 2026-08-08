import Foundation

/// The engine used when there is no engine.
///
/// It answers promptly with `GuardSource.none` and no error, because a build
/// that ships without an identification adapter is a supported configuration
/// rather than a broken one. Everything upstream treats "Guard produced
/// nothing" the same way whatever the reason, so this needs no special case
/// anywhere else.
public final class NoopSignalEngine: SignalEngine {

    public init() {}

    public func start(config: GuardConfig) {}

    public func identify(timeoutMs: Int64, handler: @escaping EngineResultHandler) {
        handler(GuardSignal.none(), nil, nil)
    }

    public func shutdown() {}
}
