import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The diagnostic half of the bootstrap request.
///
/// Every field defaults rather than failing. None of them is load-bearing, since
/// the server answers the same way without them, so a device that will not
/// report its model is not a device that should go unmeasured.
///
/// **Nothing read here identifies anybody.** No advertising identifier, no
/// vendor identifier, no name. See docs/SDK.md, "Security properties".
public enum DeviceInfoReader {

    static let unknown = "unknown"

    public static func read(sdkVersion: String) -> DeviceInfo {
        DeviceInfo(
            sdkVersion: sdkVersion,
            osVersion: osVersion(),
            bundleId: Bundle.main.bundleIdentifier ?? unknown,
            appVersion: appVersion(),
            deviceModel: deviceModel(),
            locale: Locale.current.identifier
        )
    }

    private static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The marketing version, which is what a developer recognises, rather than
    /// the build number, which changes on every CI run.
    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? unknown
    }

    /// The hardware identifier, such as `iPhone15,3`.
    ///
    /// `uname` rather than `UIDevice.model`, which answers "iPhone" for every
    /// iPhone ever made and is therefore useless for the one thing a device
    /// model is read for, which is telling a fleet apart when something only
    /// breaks on one of them.
    private static func deviceModel() -> String {
        #if canImport(Darwin)
        var system = utsname()
        guard uname(&system) == 0 else { return unknown }

        let model = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: system.machine)) {
                String(cString: $0)
            }
        }
        return model.isEmpty ? unknown : model
        #else
        return unknown
        #endif
    }
}
