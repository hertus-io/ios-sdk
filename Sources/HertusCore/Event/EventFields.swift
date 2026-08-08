import Foundation

/// The refinements in `sdk/contract/values.yaml`, applied to the typed fields
/// of the event classes.
///
/// Separate from `EventParameters.Builder` because these are the rules for
/// named fields a class declares, not for the free-form map a host app fills
/// in. Both end in the same place: a refused value is dropped and recorded,
/// never thrown.
enum EventFields {

    /// Wire keys, written once so the classes and the contract cannot drift
    /// apart.
    static let amount = "amount"
    static let currency = "currency"
    static let productId = "product_id"
    static let transactionId = "transaction_id"
    static let receipt = "receipt"
    static let periodDays = "period_days"
    static let source = "source"
    static let network = "network"
    static let placement = "placement"

    static let maxIdentifierLength = 256

    /// Store receipts run to several kilobytes, so they are exempt from the
    /// ordinary string limit. Truncating one leaves the server unable to verify
    /// a sale while every number upstream still looks right, which is the kind
    /// of fault found by reconciling revenue a month later.
    static let maxReceiptLength = 16 * 1024

    /// Matches `eventName` in the contract.
    static func isValidEventName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
        }
    }

    /// ISO 4217: three uppercase ASCII letters, and nothing else.
    static func isValidCurrency(_ currency: String) -> Bool {
        currency.count == 3 && currency.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }
}

extension EventParameters.Builder {

    /// Adds a monetary amount, refusing anything not finite or below zero.
    ///
    /// A negative amount is almost always a refund the host app meant to report
    /// differently, and admitting it here would put a negative row in somebody's
    /// revenue total without anything marking it as deliberate.
    @discardableResult
    mutating func putAmount(_ key: String, _ amount: Double) -> EventParameters.Builder {
        if !amount.isFinite {
            return putRefused(key, "not a finite number")
        }
        if amount < 0 {
            return putRefused(key, "a monetary amount cannot be negative")
        }
        return put(key, amount)
    }

    /// Adds a currency code, refusing anything that is not three uppercase
    /// letters.
    @discardableResult
    mutating func putCurrency(_ key: String, _ currency: String) -> EventParameters.Builder {
        guard EventFields.isValidCurrency(currency) else {
            return putRefused(key, "not an ISO 4217 code, which is three uppercase letters")
        }
        return put(key, currency)
    }

    /// Adds an opaque host-app id, truncating rather than refusing an over-long
    /// one.
    @discardableResult
    mutating func putIdentifier(_ key: String, _ value: String) -> EventParameters.Builder {
        put(key, String(value.prefix(EventFields.maxIdentifierLength)))
    }

    /// Adds an optional id, ignoring nil.
    @discardableResult
    mutating func putIdentifierIfPresent(_ key: String, _ value: String?) -> EventParameters.Builder {
        guard let value else { return self }
        return putIdentifier(key, value)
    }

    /// Adds a store receipt whole, under `maxReceiptLength` rather than the
    /// ordinary string limit.
    @discardableResult
    mutating func putReceiptIfPresent(_ key: String, _ receipt: String?) -> EventParameters.Builder {
        guard let receipt else { return self }
        return putText(key, receipt, maxLength: EventFields.maxReceiptLength)
    }
}
