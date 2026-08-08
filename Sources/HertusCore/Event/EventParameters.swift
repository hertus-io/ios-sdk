import Foundation

/// The detail carried alongside an event name.
///
/// Immutable, and built through `Builder` so that a value which cannot be sent
/// is refused where the developer wrote it rather than by the server hours
/// later.
///
/// ```swift
/// let parameters = EventParameters.build {
///     $0.put("level", 12)
///     $0.put("world", "forest")
/// }
/// ```
///
/// A refused parameter never fails the event and never throws. It is recorded
/// in `rejections` and logged once when the event is tracked, because a
/// malformed currency code is not a reason to lose the revenue figure next to
/// it.
public struct EventParameters {

    /// Enough for any event worth reporting, bounded so one cannot carry a
    /// database row.
    public static let maxParameters = 64

    public static let maxKeyLength = 128

    /// Insertion ordered, because a report reads better when the fields arrive
    /// in the order the developer wrote them.
    private(set) var storage: [(key: String, value: HertusValue)]

    /// Parameters that did not survive validation, and why.
    public let rejections: [Rejection]

    init(storage: [(key: String, value: HertusValue)], rejections: [Rejection]) {
        self.storage = storage
        self.rejections = rejections
    }

    /// Shared, because most events carry none.
    public static let empty = EventParameters(storage: [], rejections: [])

    /// How many parameters survived validation.
    public var count: Int { storage.count }

    public var isEmpty: Bool { storage.isEmpty }

    /// The value under `key`, or nil if it was never set or was refused.
    public subscript(key: String) -> HertusValue? {
        storage.first { $0.key == key }?.value
    }

    public func contains(_ key: String) -> Bool { self[key] != nil }

    /// The keys that survived validation, in insertion order.
    public var keys: [String] { storage.map(\.key) }

    /// A copy with `other` merged over this one. Later writes win, matching
    /// `Builder.put`.
    public func merged(with other: EventParameters) -> EventParameters {
        var builder = Builder()
        builder.putAll(self)
        builder.putAll(other)
        return builder.build()
    }

    /// One parameter that did not survive validation, and why.
    ///
    /// Carries the key and a fixed reason, never the value: the value is the
    /// part that might be somebody's personal data, and this ends up in a log
    /// line.
    public struct Rejection: Equatable, CustomStringConvertible {
        public let key: String
        public let reason: String

        init(key: String, reason: String) {
            self.key = key
            self.reason = reason
        }

        public var description: String { "\(key) (\(reason))" }
    }

    /// Collects parameters, applying each type's limits as they arrive.
    ///
    /// Typed overloads rather than a dictionary, so that autocompletion lists
    /// what a parameter may hold and the compiler rejects what it may not.
    public struct Builder {

        private var storage: [(key: String, value: HertusValue)] = []
        private var rejections: [Rejection] = []

        public init() {}

        @discardableResult
        public mutating func put(_ key: String, _ value: String) -> Builder {
            set(key) { HertusValue.of(value) }
        }

        @discardableResult
        public mutating func put(_ key: String, _ value: Int) -> Builder {
            set(key) { HertusValue.of(value) }
        }

        @discardableResult
        public mutating func put(_ key: String, _ value: Int64) -> Builder {
            set(key) { HertusValue.of(value) }
        }

        /// Refused when `value` is NaN or infinite; see `HertusValue.of`.
        @discardableResult
        public mutating func put(_ key: String, _ value: Double) -> Builder {
            set(key, refusedReason: "not a finite number") { HertusValue.of(value) }
        }

        @discardableResult
        public mutating func put(_ key: String, _ value: Bool) -> Builder {
            set(key) { HertusValue.of(value) }
        }

        /// Ignores a nil `value` rather than storing an empty parameter.
        @discardableResult
        public mutating func putIfPresent(_ key: String, _ value: String?) -> Builder {
            guard let value else { return self }
            return put(key, value)
        }

        /// Ignores a nil `value` rather than storing an empty parameter.
        @discardableResult
        public mutating func putIfPresent(_ key: String, _ value: Int64?) -> Builder {
            guard let value else { return self }
            return put(key, value)
        }

        /// Ignores a nil `value` rather than storing an empty parameter.
        @discardableResult
        public mutating func putIfPresent(_ key: String, _ value: Double?) -> Builder {
            guard let value else { return self }
            return put(key, value)
        }

        @discardableResult
        public mutating func putAll(_ other: EventParameters) -> Builder {
            for entry in other.storage { write(entry.key, entry.value) }
            rejections.append(contentsOf: other.rejections)
            return self
        }

        /// Stores text under a limit other than `HertusValue.maxStringLength`.
        ///
        /// Internal, because the only field that needs it is a store receipt
        /// and the exemption should not be reachable from a host app.
        @discardableResult
        mutating func putText(_ key: String, _ value: String, maxLength: Int) -> Builder {
            set(key) { HertusValue.ofText(value, maxLength: maxLength) }
        }

        /// Records a refusal decided elsewhere, such as by one of the typed
        /// field rules in `EventFields`.
        @discardableResult
        mutating func putRefused(_ key: String, _ reason: String) -> Builder {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            rejections.append(Rejection(key: trimmed.isEmpty ? key : trimmed, reason: reason))
            return self
        }

        public func build() -> EventParameters {
            EventParameters(storage: storage, rejections: rejections)
        }

        /// Validates the key, then the value, recording a rejection for
        /// whichever fails. Keeping both checks here means every `put` overload
        /// refuses the same things for the same stated reasons.
        @discardableResult
        private mutating func set(
            _ key: String,
            refusedReason: String = "refused",
            produce: () -> HertusValue?
        ) -> Builder {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                rejections.append(Rejection(key: key, reason: "the key is blank"))
            } else if trimmed.count > EventParameters.maxKeyLength {
                rejections.append(
                    Rejection(
                        key: String(trimmed.prefix(EventParameters.maxKeyLength)),
                        reason: "the key is longer than \(EventParameters.maxKeyLength)"
                    )
                )
            } else if storage.count >= EventParameters.maxParameters,
                      !storage.contains(where: { $0.key == trimmed }) {
                rejections.append(
                    Rejection(
                        key: trimmed,
                        reason: "the event already holds \(EventParameters.maxParameters) parameters"
                    )
                )
            } else if let value = produce() {
                write(trimmed, value)
            } else {
                rejections.append(Rejection(key: trimmed, reason: refusedReason))
            }

            return self
        }

        /// Overwrites in place so that a later write wins without moving the
        /// parameter to the end of the order.
        private mutating func write(_ key: String, _ value: HertusValue) {
            if let index = storage.firstIndex(where: { $0.key == key }) {
                storage[index].value = value
            } else {
                storage.append((key: key, value: value))
            }
        }
    }

    /// The closure form of `Builder`, so parameters can be written inline.
    ///
    /// ```swift
    /// EventParameters.build { $0.put("cart_size", 3) }
    /// ```
    public static func build(_ configure: (inout Builder) -> Void) -> EventParameters {
        var builder = Builder()
        configure(&builder)
        return builder.build()
    }
}

extension EventParameters: CustomStringConvertible {
    public var description: String {
        "EventParameters(\(storage.count) value(s), \(rejections.count) refused)"
    }
}
