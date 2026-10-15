public import Foundation

public struct SubscriptionGroup: Equatable, Sendable {
    public let id: String
    public let referenceName: String
}

public struct SubscriptionGroupLocalization: Equatable, Sendable {
    public let id: String
    public let locale: String
    public let name: String?
}

/// An auto-renewable subscription.
public struct Subscription: Equatable, Sendable {
    public let id: String
    public let productID: String
    /// The ISO 8601 period: `P1M`, `P1Y`.
    public let period: String?
    public let familySharable: Bool
    public let settings: SubscriptionSettings
}

/// What can change on a subscription after it is created.
public struct SubscriptionSettings: FieldSet {
    public var referenceName: String?
    public var level: Int?
    public var reviewNote: String?

    public init() {}

    public init(referenceName: String?, level: Int?, reviewNote: String?) {
        self.referenceName = referenceName
        self.level = level
        self.reviewNote = reviewNote
    }

    public static let properties: [Property<Self>] = [
        Property("referenceName", \.referenceName),
        Property("level", \.level),
        Property("reviewNote", \.reviewNote),
    ]
}

/// An in-app product's name and description in one locale.
public struct ProductText: FieldSet {
    public var name: String?
    public var description: String?

    public init() {}

    public init(name: String?, description: String?) {
        self.name = name
        self.description = description
    }

    public static let properties: [Property<Self>] = [
        Property("name", \.name),
        Property("description", \.description),
    ]
}

/// A price a subscription can be set to, in one territory.
public struct PricePoint: Equatable, Sendable {
    public let id: String
    public let customerPrice: String?
    public let territory: String?
}

/// An in-app product's App Review screenshot.
public struct ProductReviewScreenshot: Equatable, Sendable {
    public let id: String
    public let checksum: String?
}

extension AppStoreConnect {
    /// The ordinary subscription plan, paid each period in full. App Store
    /// Connect also has `MONTHLY`, an annual plan paid in instalments, whose
    /// price points and prices are kept apart from these.
    public static let upfront = "UPFRONT"

    /// App Store Connect's `subscriptionPeriod` for an ISO 8601 period.
    public static let periods: [String: String] = [
        "P1W": "ONE_WEEK", "P1M": "ONE_MONTH", "P2M": "TWO_MONTHS",
        "P3M": "THREE_MONTHS", "P6M": "SIX_MONTHS", "P1Y": "ONE_YEAR",
    ]

    // MARK: - Groups

    public func subscriptionGroups(appID: String) async throws -> [SubscriptionGroup] {
        try await all { cursor in
            let page = try await client.appsSubscriptionGroupsGetToManyRelated(.init(path: .init(id: appID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.map { SubscriptionGroup(id: $0.id, referenceName: $0.attributes?.referenceName ?? "") }, page.links.next)
        }
    }

    public func createSubscriptionGroup(appID: String, referenceName: String) async throws -> String {
        try await call {
            try await client.subscriptionGroupsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(referenceName: referenceName),
                relationships: .init(app: .init(data: .init(id: appID, _type: .apps))),
                _type: .subscriptionGroups
            ))))).created.body.json.data.id
        }
    }

    public func subscriptionGroupLocalizations(groupID: String) async throws -> [SubscriptionGroupLocalization] {
        try await all { cursor in
            let page = try await client.subscriptionGroupsSubscriptionGroupLocalizationsGetToManyRelated(.init(path: .init(id: groupID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { localization in
                localization.attributes?.locale.map {
                    SubscriptionGroupLocalization(id: localization.id, locale: $0, name: localization.attributes?.name)
                }
            }, page.links.next)
        }
    }

    public func createSubscriptionGroupLocalization(groupID: String, locale: String, name: String) async throws {
        _ = try await call {
            try await client.subscriptionGroupLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(locale: locale, name: name),
                relationships: .init(subscriptionGroup: .init(data: .init(id: groupID, _type: .subscriptionGroups))),
                _type: .subscriptionGroupLocalizations
            ))))).created
        }
    }

    public func renameSubscriptionGroupLocalization(id: String, name: String) async throws {
        _ = try await call {
            try await client.subscriptionGroupLocalizationsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(name: name), id: id, _type: .subscriptionGroupLocalizations
            ))))).ok
        }
    }

    // MARK: - Subscriptions

    public func subscriptions(groupID: String) async throws -> [Subscription] {
        try await all { cursor in
            let page = try await client.subscriptionGroupsSubscriptionsGetToManyRelated(.init(path: .init(id: groupID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { subscription in
                guard let attributes = subscription.attributes, let productID = attributes.productId else { return nil }
                return Subscription(
                    id: subscription.id,
                    productID: productID,
                    period: attributes.subscriptionPeriod.flatMap { period in Self.periods.first { $0.value == period }?.key },
                    familySharable: attributes.familySharable ?? false,
                    settings: SubscriptionSettings(referenceName: attributes.name, level: attributes.groupLevel,
                                                   reviewNote: attributes.reviewNote)
                )
            }, page.links.next)
        }
    }

    /// Family Sharing is off: once on, App Store Connect cannot turn it off.
    public func createSubscription(groupID: String, productID: String, period: String, familySharable: Bool,
                                   settings: SubscriptionSettings) async throws -> String {
        try await call {
            try await client.subscriptionsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(
                    familySharable: familySharable,
                    groupLevel: settings.level,
                    name: settings.referenceName ?? productID,
                    productId: productID,
                    reviewNote: settings.reviewNote,
                    subscriptionPeriod: Self.periods[period]
                ),
                relationships: .init(group: .init(data: .init(id: groupID, _type: .subscriptionGroups))),
                _type: .subscriptions
            ))))).created.body.json.data.id
        }
    }

    public func updateSubscription(id: String, _ changes: SubscriptionSettings, familySharable: Bool?) async throws {
        _ = try await call {
            try await client.subscriptionsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(familySharable: familySharable, groupLevel: changes.level, name: changes.referenceName,
                                  reviewNote: changes.reviewNote),
                id: id, _type: .subscriptions
            ))))).ok
        }
    }

    public func subscriptionLocalizations(subscriptionID: String) async throws -> [String: Localized<ProductText>] {
        let localizations = try await all { cursor in
            let page = try await client.subscriptionsSubscriptionLocalizationsGetToManyRelated(.init(path: .init(id: subscriptionID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { localization -> Localized<ProductText>? in
                guard let attributes = localization.attributes, let locale = attributes.locale else { return nil }
                return Localized(id: localization.id, locale: locale,
                                 text: ProductText(name: attributes.name, description: attributes.description))
            }, page.links.next)
        }
        return Dictionary(localizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func createSubscriptionLocalization(subscriptionID: String, locale: String, text: ProductText) async throws {
        _ = try await call {
            try await client.subscriptionLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(description: text.description, locale: locale, name: text.name ?? ""),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID, _type: .subscriptions))),
                _type: .subscriptionLocalizations
            ))))).created
        }
    }

    public func updateSubscriptionLocalization(id: String, _ changes: ProductText) async throws {
        _ = try await call {
            try await client.subscriptionLocalizationsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(description: changes.description, name: changes.name),
                id: id, _type: .subscriptionLocalizations
            ))))).ok
        }
    }

    // MARK: - Availability and prices

    /// Whether the subscription's upfront plan has an availability record.
    public func hasSubscriptionAvailability(subscriptionID: String) async throws -> Bool {
        let availabilities = try await all { cursor in
            let page = try await client.subscriptionsPlanAvailabilitiesGetToManyRelated(.init(
                path: .init(id: subscriptionID), query: .init(limit: 50, cursor: cursor)
            )).ok.body.json
            return (page.data, page.links.next)
        }
        return availabilities.contains { $0.attributes?.planType == Self.upfront }
    }

    /// Every territory's id.
    public func territories() async throws -> [String] {
        try await all { cursor in
            let page = try await client.territoriesGetCollection(.init(query: .init(limit: 200, cursor: cursor))).ok.body.json
            return (page.data.map(\.id), page.links.next)
        }
    }

    /// Makes the upfront plan available in `territories` and every new one.
    public func createSubscriptionAvailability(subscriptionID: String, territories: [String]) async throws {
        _ = try await call {
            try await client.subscriptionPlanAvailabilitiesCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(availableInNewTerritories: true, planType: Self.upfront),
                relationships: .init(
                    availableTerritories: .init(data: territories.map { .init(id: $0, _type: .territories) }),
                    subscription: .init(data: .init(id: subscriptionID, _type: .subscriptions))
                ),
                _type: .subscriptionPlanAvailabilities
            ))))).created
        }
    }

    /// The subscription's upfront price points in one territory.
    public func pricePoints(subscriptionID: String, territory: String) async throws -> [PricePoint] {
        try await all { cursor in
            let page = try await client.subscriptionsPricePointsGetToManyRelated(.init(
                path: .init(id: subscriptionID),
                query: .init(filter_lbrack_territory_rbrack_: [territory], filter_lbrack_planType_rbrack_: [Self.upfront],
                             limit: 200, cursor: cursor)
            )).ok.body.json
            return (page.data.map { PricePoint(id: $0.id, customerPrice: $0.attributes?.customerPrice, territory: territory) },
                    page.links.next)
        }
    }

    /// Apple's equivalent of an upfront price point in every other territory.
    public func equalizations(pricePointID: String) async throws -> [PricePoint] {
        try await all { cursor in
            let page = try await client.subscriptionPricePointsEqualizationsGetToManyRelated(.init(
                path: .init(id: pricePointID),
                query: .init(filter_lbrack_planType_rbrack_: [Self.upfront], limit: 200, include: [.territory], cursor: cursor)
            )).ok.body.json
            return (page.data.map {
                PricePoint(id: $0.id, customerPrice: $0.attributes?.customerPrice, territory: $0.relationships?.territory?.data?.id)
            }, page.links.next)
        }
    }

    /// The upfront price new subscribers pay today in each territory, by
    /// territory id: the latest that has started, leaving out the prices kept
    /// for existing subscribers.
    public func prices(subscriptionID: String, today: Date = Date()) async throws -> [String: PricePoint] {
        // App Store Connect's dates: `2026-10-15`.
        let day = today.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
        let prices = try await all { cursor in
            let page = try await client.subscriptionsPricesGetToManyRelated(.init(
                path: .init(id: subscriptionID),
                query: .init(limit: 200, include: [.subscriptionPricePoint, .territory], cursor: cursor)
            )).ok.body.json
            let customerPrices = Dictionary((page.included ?? []).compactMap { included -> (String, String?)? in
                guard case .subscriptionPricePoints(let point) = included else { return nil }
                return (point.id, point.attributes?.customerPrice)
            }, uniquingKeysWith: { first, _ in first })
            return (page.data.compactMap { price -> (start: String, point: PricePoint)? in
                guard price.attributes?.planType ?? Self.upfront == Self.upfront, price.attributes?.preserved != true,
                      let territory = price.relationships?.territory?.data?.id,
                      let point = price.relationships?.subscriptionPricePoint?.data?.id
                else { return nil }
                return (price.attributes?.startDate ?? "", PricePoint(id: point, customerPrice: customerPrices[point] ?? nil,
                                                                     territory: territory))
            }, page.links.next)
        }
        var current: [String: (start: String, point: PricePoint)] = [:]
        for price in prices where price.start <= day {
            guard let territory = price.point.territory else { continue }
            if let known = current[territory], known.start >= price.start { continue }
            current[territory] = price
        }
        return current.mapValues(\.point)
    }

    public func createSubscriptionPrice(subscriptionID: String, pricePointID: String, territory: String) async throws {
        _ = try await call {
            try await client.subscriptionPricesCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(planType: Self.upfront, preserveCurrentPrice: false),
                relationships: .init(
                    subscription: .init(data: .init(id: subscriptionID, _type: .subscriptions)),
                    subscriptionPricePoint: .init(data: .init(id: pricePointID, _type: .subscriptionPricePoints)),
                    territory: .init(data: .init(id: territory, _type: .territories))
                ),
                _type: .subscriptionPrices
            ))))).created
        }
    }

    // MARK: - Review screenshot

    public func subscriptionReviewScreenshot(subscriptionID: String) async throws -> ProductReviewScreenshot? {
        do {
            guard let screenshot = try await call({
                try await client.subscriptionsAppStoreReviewScreenshotGetToOneRelated(.init(path: .init(id: subscriptionID))).ok.body.json.data
            }) else { return nil }
            return ProductReviewScreenshot(id: screenshot.id, checksum: screenshot.attributes?.sourceFileChecksum)
        } catch let error as ASCError where error.isNotFound {
            return nil
        }
    }

    public func deleteProductReviewScreenshot(id: String) async throws {
        _ = try await call {
            try await client.subscriptionAppStoreReviewScreenshotsDeleteInstance(.init(path: .init(id: id))).noContent
        }
    }

    public func uploadProductReviewScreenshot(subscriptionID: String, fileName: String, data: Data) async throws {
        let reservation = try present(try await call {
            try await client.subscriptionAppStoreReviewScreenshotsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(fileName: fileName, fileSize: data.count),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID, _type: .subscriptions))),
                _type: .subscriptionAppStoreReviewScreenshots
            ))))).created.body.json.data
        }, "the review screenshot reservation")
        try await transfer(data, operations: reservation.attributes?.uploadOperations ?? [])
        _ = try await call {
            try await client.subscriptionAppStoreReviewScreenshotsUpdateInstance(.init(path: .init(id: reservation.id), body: .json(.init(data: .init(
                attributes: .init(sourceFileChecksum: Self.md5(data), uploaded: true),
                id: reservation.id, _type: .subscriptionAppStoreReviewScreenshots
            ))))).ok
        }
    }
}
