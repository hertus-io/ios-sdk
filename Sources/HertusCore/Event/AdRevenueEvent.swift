import Foundation

/// Revenue attributed to an ad impression, as reported by a mediation platform.
///
/// The amounts are small and the volume is large, so this is the event most
/// likely to arrive thousands of times in a session. It carries no transaction
/// id because no store issued one: the mediation platform's own reporting is
/// the reconciliation point.
///
/// ```swift
/// Hertus.track(
///     AdRevenueEvent(
///         source: "applovin_max",
///         amount: 0.0031,
///         currency: "USD",
///         network: ad.networkName,
///         placement: ad.placement
///     )
/// )
/// ```
public final class AdRevenueEvent: HertusEvent {

    public static let wireName = "hertus.ad_revenue"

    /// Which mediation platform reported this.
    public let source: String

    public let amount: Double
    public let currency: String

    /// The ad network that filled the impression, when the platform reports it.
    public let network: String?

    public let placement: String?

    public init(
        source: String,
        amount: Double,
        currency: String,
        network: String? = nil,
        placement: String? = nil,
        additional: EventParameters = .empty
    ) {
        self.source = source
        self.amount = amount
        self.currency = currency
        self.network = network
        self.placement = placement

        var builder = EventParameters.Builder()
        builder.putAll(additional)
        builder.putIdentifier(EventFields.source, source)
        builder.putAmount(EventFields.amount, amount)
        builder.putCurrency(EventFields.currency, currency)
        builder.putIdentifierIfPresent(EventFields.network, network)
        builder.putIdentifierIfPresent(EventFields.placement, placement)

        super.init(name: AdRevenueEvent.wireName, parameters: builder.build())
    }
}
