public import Foundation

/// The in-app products an app sells, as `ProductSource.command` prints them
/// or `ProductSource.catalogue` holds them:
///
/// ```json
/// {
///   "subscriptionGroups": [{
///     "referenceName": "Example Plus",
///     "localizations": {"en": {"name": "Example Plus"}},
///     "subscriptions": [{
///       "productID": "com.example.plus.monthly",
///       "referenceName": "Plus Monthly",
///       "level": 1,
///       "period": "P1M",
///       "price": "4.99",
///       "localizations": {"en": {"name": "Plus", "description": "Everything, every month."}}
///     }]
///   }],
///   "inAppPurchases": [{
///     "productID": "com.example.lifetime",
///     "referenceName": "Lifetime",
///     "kind": "NON_CONSUMABLE",
///     "price": "49.99",
///     "familySharable": true,
///     "localizations": {"en": {"name": "Lifetime", "description": "Everything, once."}}
///   }]
/// }
/// ```
///
/// Localizations are keyed by the project's locale codes. Prices are in the
/// base territory's currency; every other territory gets Apple's equalised
/// price.
public struct ProductCatalogue: Codable, Equatable, Sendable {
    public var subscriptionGroups: [SubscriptionGroup]
    /// One-time purchases.
    public var inAppPurchases: [InAppPurchase]

    public init(subscriptionGroups: [SubscriptionGroup] = [], inAppPurchases: [InAppPurchase] = []) {
        self.subscriptionGroups = subscriptionGroups
        self.inAppPurchases = inAppPurchases
    }

    private enum CodingKeys: String, CodingKey { case subscriptionGroups, inAppPurchases }

    /// Either list may be left out of what a command prints.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionGroups = try container.decodeIfPresent([SubscriptionGroup].self, forKey: .subscriptionGroups) ?? []
        inAppPurchases = try container.decodeIfPresent([InAppPurchase].self, forKey: .inAppPurchases) ?? []
    }

    public struct SubscriptionGroup: Codable, Equatable, Sendable {
        /// App Store Connect's name for the group, which customers never see.
        public var referenceName: String
        public var localizations: [String: GroupText]
        public var subscriptions: [Subscription]

        public init(referenceName: String, localizations: [String: GroupText], subscriptions: [Subscription]) {
            self.referenceName = referenceName
            self.localizations = localizations
            self.subscriptions = subscriptions
        }
    }

    public struct GroupText: Codable, Equatable, Sendable {
        /// The group's name on the subscription sheet and in Settings.
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    public struct Subscription: Codable, Equatable, Sendable {
        public var productID: String
        /// App Store Connect's name for it, unique within the app.
        public var referenceName: String
        /// Rank in the group: 1 is the highest level of service. Products of
        /// one level are crossgrades of each other.
        public var level: Int
        public var period: Period
        /// The base territory's customer price: `4.99`.
        public var price: String
        /// Once on, App Store Connect keeps it on. A catalogue without it
        /// means off.
        public var familySharable: Bool
        /// What new subscribers get first, in every territory the
        /// subscription is sold in. The App Store gives each Apple Account
        /// one per subscription group.
        public var introductoryOffer: IntroductoryOffer?
        public var localizations: [String: ProductText]

        public init(productID: String, referenceName: String, level: Int, period: Period, price: String,
                    familySharable: Bool = false, introductoryOffer: IntroductoryOffer? = nil,
                    localizations: [String: ProductText]) {
            self.productID = productID
            self.referenceName = referenceName
            self.level = level
            self.period = period
            self.price = price
            self.familySharable = familySharable
            self.introductoryOffer = introductoryOffer
            self.localizations = localizations
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            productID = try container.decode(String.self, forKey: .productID)
            referenceName = try container.decode(String.self, forKey: .referenceName)
            level = try container.decode(Int.self, forKey: .level)
            period = try container.decode(Period.self, forKey: .period)
            price = try container.decode(String.self, forKey: .price)
            familySharable = try container.decodeIfPresent(Bool.self, forKey: .familySharable) ?? false
            introductoryOffer = try container.decodeIfPresent(IntroductoryOffer.self, forKey: .introductoryOffer)
            localizations = try container.decode([String: ProductText].self, forKey: .localizations)
        }
    }

    public struct ProductText: Codable, Equatable, Sendable {
        public var name: String
        public var description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public struct InAppPurchase: Codable, Equatable, Sendable {
        /// App Store Connect's `inAppPurchaseType`.
        public enum Kind: String, Codable, Sendable {
            case consumable = "CONSUMABLE"
            case nonConsumable = "NON_CONSUMABLE"
            case nonRenewingSubscription = "NON_RENEWING_SUBSCRIPTION"
        }

        public var productID: String
        /// App Store Connect's name for it, unique within the app.
        public var referenceName: String
        public var kind: Kind
        /// The base territory's customer price: `49.99`.
        public var price: String
        /// Whether a family shares one purchase. Only a non-consumable can,
        /// and once on, App Store Connect cannot turn it off.
        public var familySharable: Bool
        public var localizations: [String: ProductText]

        public init(productID: String, referenceName: String, kind: Kind, price: String, familySharable: Bool,
                    localizations: [String: ProductText]) {
            self.productID = productID
            self.referenceName = referenceName
            self.kind = kind
            self.price = price
            self.familySharable = familySharable
            self.localizations = localizations
        }
    }

    /// An introductory offer. Free trials only: the paid kinds need a price
    /// point in every territory, which nothing here asks for yet.
    public struct IntroductoryOffer: Codable, Equatable, Sendable {
        /// How long it lasts, as App Store Connect spells it.
        public enum Duration: String, Codable, CaseIterable, Sendable {
            case threeDays = "THREE_DAYS"
            case oneWeek = "ONE_WEEK"
            case twoWeeks = "TWO_WEEKS"
            case oneMonth = "ONE_MONTH"
            case twoMonths = "TWO_MONTHS"
            case threeMonths = "THREE_MONTHS"
            case sixMonths = "SIX_MONTHS"
            case oneYear = "ONE_YEAR"

            /// The ISO 8601 period a StoreKit configuration file takes.
            public var period: String {
                switch self {
                case .threeDays: "P3D"
                case .oneWeek: "P1W"
                case .twoWeeks: "P2W"
                case .oneMonth: "P1M"
                case .twoMonths: "P2M"
                case .threeMonths: "P3M"
                case .sixMonths: "P6M"
                case .oneYear: "P1Y"
                }
            }
        }

        /// App Store Connect's `offerMode` for a free trial.
        public static let freeTrialMode = "FREE_TRIAL"

        public var duration: Duration

        public static func freeTrial(_ duration: Duration) -> IntroductoryOffer {
            IntroductoryOffer(duration: duration)
        }
    }

    /// A subscription period, as ISO 8601 spells it and StoreKit files use it.
    public enum Period: String, Codable, CaseIterable, Sendable {
        case week = "P1W"
        case month = "P1M"
        case twoMonths = "P2M"
        case threeMonths = "P3M"
        case sixMonths = "P6M"
        case year = "P1Y"
    }

    /// The project's catalogue: the one it holds, or what its command prints
    /// when run at the repository root.
    public static func load(_ project: Project, root: URL) async throws -> ProductCatalogue {
        guard let products = project.products else { throw CatalogueError.notConfigured }
        switch products.source {
        case .catalogue(let catalogue):
            return catalogue
        case .command(let command):
            let output = try await Shell.run(command, in: root)
            do {
                return try JSONDecoder().decode(ProductCatalogue.self, from: output)
            } catch {
                throw CatalogueError.unreadable(command, error)
            }
        }
    }

    /// What would sell the wrong thing, or that App Store Connect refuses
    /// outright. Text lengths are left to App Store Connect, which checks them
    /// when they are written and documents no limit for in-app products.
    public func problems(project: Project) -> [Problem] {
        var problems: [Problem] = []
        let primary = project.primaryLocale.code
        let codes = Set(project.locales.map(\.code))
        var productIDs: Set<String> = []
        func checkLanguages(_ languages: some Collection<String>, _ subject: String) {
            if !languages.contains(primary) { problems.append(.error("\(subject) has no \(primary) text")) }
            for language in languages.sorted() where !codes.contains(language) {
                problems.append(.error("\(subject) has \(language), which is not a configured locale"))
            }
        }
        if Set(subscriptionGroups.map(\.referenceName)).count != subscriptionGroups.count {
            problems.append(.error("two subscription groups share a reference name"))
        }
        for group in subscriptionGroups {
            checkLanguages(group.localizations.keys, "group \(group.referenceName)")
            for subscription in group.subscriptions {
                let subject = subscription.productID
                if !productIDs.insert(subscription.productID).inserted {
                    problems.append(.error("\(subject) is listed twice"))
                }
                if subscription.level < 1 { problems.append(.error("\(subject): level starts at 1")) }
                if subscription.price.wholeMatch(of: /\d+\.\d{2}/) == nil {
                    problems.append(.error("\(subject): price \(subscription.price) is not a price like 4.99"))
                }
                checkLanguages(subscription.localizations.keys, subject)
            }
        }
        for purchase in inAppPurchases {
            let subject = purchase.productID
            if !productIDs.insert(purchase.productID).inserted {
                problems.append(.error("\(subject) is listed twice"))
            }
            if purchase.price.wholeMatch(of: /\d+\.\d{2}/) == nil {
                problems.append(.error("\(subject): price \(purchase.price) is not a price like 4.99"))
            }
            if purchase.familySharable, purchase.kind != .nonConsumable {
                problems.append(.error("\(subject): only a non-consumable can be shared with a family"))
            }
            checkLanguages(purchase.localizations.keys, subject)
        }
        return problems
    }
}

public enum CatalogueError: Error, CustomStringConvertible {
    case notConfigured
    case unreadable(String, Error)

    public var description: String {
        switch self {
        case .notConfigured: "The project has no products."
        case .unreadable(let command, let error): "`\(command)` did not print a product catalogue: \(error)"
        }
    }
}
