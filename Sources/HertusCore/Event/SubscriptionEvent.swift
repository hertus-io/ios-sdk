import Foundation

/// A recurring store transaction, whether the first one or a renewal.
///
/// Separate from `PurchaseEvent` because the two are counted differently: a
/// renewal is revenue from a user acquired months ago, and folding it into
/// purchases would credit it to whichever campaign happened to be running this
/// week.
///
/// ```swift
/// Hertus.track(
///     SubscriptionEvent(
///         productId: "pro_annual",
///         amount: 39.99,
///         currency: "USD",
///         transactionId: transaction.id,
///         periodDays: 365
///     )
/// )
/// ```
public final class SubscriptionEvent: HertusEvent {

    public static let wireName = "hertus.subscription"

    public let productId: String
    public let amount: Double
    public let currency: String
    public let transactionId: String

    /// Billing period length. Nil when the host app does not know it.
    public let periodDays: Int64?

    public init(
        productId: String,
        amount: Double,
        currency: String,
        transactionId: String,
        periodDays: Int64? = nil,
        additional: EventParameters = .empty
    ) {
        self.productId = productId
        self.amount = amount
        self.currency = currency
        self.transactionId = transactionId
        self.periodDays = periodDays

        var builder = EventParameters.Builder()
        builder.putAll(additional)
        builder.putIdentifier(EventFields.productId, productId)
        builder.putAmount(EventFields.amount, amount)
        builder.putCurrency(EventFields.currency, currency)
        builder.putIdentifier(EventFields.transactionId, transactionId)
        builder.putIfPresent(EventFields.periodDays, periodDays)

        super.init(name: SubscriptionEvent.wireName, parameters: builder.build())
    }
}
