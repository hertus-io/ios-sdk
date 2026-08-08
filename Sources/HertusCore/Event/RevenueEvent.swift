import Foundation

/// Money earned from a user action, where no store transaction backs it.
///
/// For a purchase the stores can vouch for, use `PurchaseEvent` instead: it
/// carries a transaction id the server uses to reject duplicates, which this
/// cannot.
///
/// ```swift
/// Hertus.track(RevenueEvent(amount: 4.99, currency: "USD", productId: "pro_monthly"))
/// ```
///
/// A negative or non-finite `amount`, or a `currency` that is not an ISO 4217
/// code, is dropped and recorded in `rejections`. The event is still sent,
/// because the fact that revenue happened is worth more than the figure
/// attached to it.
public final class RevenueEvent: HertusEvent {

    public static let wireName = "hertus.revenue"

    public let amount: Double
    public let currency: String
    public let productId: String?

    public init(
        amount: Double,
        currency: String,
        productId: String? = nil,
        additional: EventParameters = .empty
    ) {
        self.amount = amount
        self.currency = currency
        self.productId = productId

        // `additional` is applied first so the typed fields win a collision. A
        // host app that puts "amount" in the map did not mean to overwrite the
        // argument it also passed by name.
        var builder = EventParameters.Builder()
        builder.putAll(additional)
        builder.putAmount(EventFields.amount, amount)
        builder.putCurrency(EventFields.currency, currency)
        builder.putIdentifierIfPresent(EventFields.productId, productId)

        super.init(name: RevenueEvent.wireName, parameters: builder.build())
    }
}
