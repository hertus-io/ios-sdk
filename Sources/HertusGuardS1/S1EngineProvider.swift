#if canImport(FingerprintPro)

import Foundation
import HertusCore

/// How `SignalEngineFactory` finds this adapter without anything referring to it
/// at compile time.
///
/// The Objective-C name is the contract. `HertusCore` holds it as a string, the
/// way the Android SDK holds a class name for `Class.forName`, so core carries no
/// dependency on this target and a build without it has no trace of the engine.
///
/// The consequence for a host app is that there is nothing to call. Adding this
/// library to a target is the whole integration, and `Hertus.initialize` decides
/// whether the engine actually runs from the environment, `guardEnabled` and the
/// server's answer.
@objc(HertusSignalEngineProviderS1)
public final class S1EngineProvider: NSObject, SignalEngineProviding {

    /// Required by the runtime lookup, which constructs this with no arguments.
    @objc public override init() {
        super.init()
    }

    public func makeSignalEngine() -> AnyObject {
        S1SignalEngine()
    }
}

#endif
