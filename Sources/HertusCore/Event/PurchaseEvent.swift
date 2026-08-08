import Foundation

/// A completed store transaction.
///
/// Distinct from `RevenueEvent` because it carries a `transactionId` and,
/// optionally, a `receipt`. Those are what let the server reject a duplicate
/// and verify the sale actually happened, which is the difference between
/// reported revenue and trusted revenue.
///
/// ```swift
/// Hertus.track(
///     PurchaseEvent(
///         productId: "pro_monthly",
///         amount: 4.99,
///         currency: "USD",
///         transactionId: transaction.id,
///         receipt: receiptString
///     )
/// )
/// ```
public final class PurchaseEvent: HertusEvent {

    public static let wireName = "hertus.purchase"

    public let productId: String
    public let amount: Double
    public let currency: String
    public let transactionId: String

    /// The store receipt, passed through untouched.
    ///
    /// The SDK never parses or validates it. A client that could tell a good
    /// receipt from a bad one could also be modified to lie about the
    /// difference, so verification is the server's job and this is a courier.
    public let receipt: String?

    public init(
        productId: String,
        amount: Double,
        currency: String,
        transactionId: String,
        receipt: String? = nil,
        additional: EventParameters = .empty
    ) {
        self.productId = productId
        self.amount = amount
        self.currency = currency
        self.transactionId = transactionId
        self.receipt = receipt

        var builder = EventParameters.Builder()
        builder.putAll(additional)
        builder.putIdentifier(EventFields.productId, productId)
        builder.putAmount(EventFields.amount, amount)
        builder.putCurrency(EventFields.currency, currency)
        builder.putIdentifier(EventFields.transactionId, transactionId)
        builder.putReceiptIfPresent(EventFields.receipt, receipt)

        super.init(name: PurchaseEvent.wireName, parameters: builder.build())
    }
}
