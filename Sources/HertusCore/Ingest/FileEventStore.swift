import Foundation

/// Queued events on disk.
///
/// One JSON array in Application Support, written atomically so a process killed
/// mid-write leaves the previous file rather than half of the new one. An SDK
/// that corrupts its own queue loses more events than one that never persisted.
///
/// **Excluded from backup.** These are unsent measurement events, not user data:
/// restoring them onto a new device would report a stranger's session as
/// somebody else's, and they are worthless by the time a restore happens anyway.
public final class FileEventStore: EventStore {

    private let url: URL?
    private let log: Logger

    /// Keyed by token and environment, for the reasons `BootstrapCache` gives:
    /// a rotated key or a switched environment must not read the other's queue.
    public init(appToken: String, environment: HertusEnvironment, log: Logger) {
        self.log = log
        self.url = FileEventStore.fileUrl(appToken: appToken, environment: environment)

        if url == nil {
            log.w("no writable directory for the event queue; events will not survive a restart")
        }
    }

    public func load() -> [String] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }

        guard let payloads = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            // A file this build cannot read is a file from a build that wrote it
            // differently. Dropping it happens once and costs one launch of
            // events; keeping it would fail on every launch forever.
            log.w("the stored event queue could not be read; discarding it")
            try? FileManager.default.removeItem(at: url)
            return []
        }

        return payloads
    }

    public func save(_ payloads: [String]) {
        guard let url else { return }

        guard payloads.isEmpty == false else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payloads) else { return }

        do {
            // Atomic, so a kill mid-write leaves the previous file intact.
            try data.write(to: url, options: .atomic)
            excludeFromBackup(url)
        } catch {
            log.v("could not persist the event queue: \(error.localizedDescription)")
        }
    }

    private func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(resource)
        #endif
    }

    private static func fileUrl(appToken: String, environment: HertusEnvironment) -> URL? {
        let manager = FileManager.default

        guard
            let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }

        let directory = base.appendingPathComponent("io.hertus.sdk", isDirectory: true)
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let key = BootstrapCache.cacheKey(appToken, environment)
        return directory.appendingPathComponent("events_\(key).json", isDirectory: false)
    }
}
