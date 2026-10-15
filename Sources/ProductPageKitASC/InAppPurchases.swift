public import Foundation

/// A one-time in-app purchase: consumable, non-consumable or a
/// non-renewing subscription.
public struct InAppPurchase: Equatable, Sendable {
    public let id: String
    public let productID: String
    /// App Store Connect's `inAppPurchaseType`: `NON_CONSUMABLE` and the rest.
    public let kind: String?
    public let familySharable: Bool
    public let settings: InAppPurchaseSettings
}

/// What can change on an in-app purchase after it is created.
public struct InAppPurchaseSettings: FieldSet {
    public var referenceName: String?
    public var reviewNote: String?

    public init() {}

    public init(referenceName: String?, reviewNote: String?) {
        self.referenceName = referenceName
        self.reviewNote = reviewNote
    }

    public static let properties: [Property<Self>] = [
        Property("name", \.referenceName),
        Property("reviewNote", \.reviewNote),
    ]
}

extension AppStoreConnect {
    public func inAppPurchases(appID: String) async throws -> [InAppPurchase] {
        try await all { cursor in
            let page = try await client.appsInAppPurchasesV2GetToManyRelated(.init(path: .init(id: appID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { purchase in
                guard let attributes = purchase.attributes, let productID = attributes.productId else { return nil }
                return InAppPurchase(id: purchase.id, productID: productID, kind: attributes.inAppPurchaseType,
                                     familySharable: attributes.familySharable ?? false,
                                     settings: InAppPurchaseSettings(referenceName: attributes.name, reviewNote: attributes.reviewNote))
            }, page.links.next)
        }
    }

    public func createInAppPurchase(appID: String, productID: String, kind: String, familySharable: Bool,
                                    settings: InAppPurchaseSettings) async throws -> String {
        try await call {
            try await client.inAppPurchasesV2CreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(familySharable: familySharable, inAppPurchaseType: kind, name: settings.referenceName ?? productID,
                                  productId: productID, reviewNote: settings.reviewNote),
                relationships: .init(app: .init(data: .init(id: appID, _type: .apps))),
                _type: .inAppPurchases
            ))))).created.body.json.data.id
        }
    }

    /// `familySharable` turns Family Sharing on; App Store Connect cannot
    /// turn it off again.
    public func updateInAppPurchase(id: String, _ changes: InAppPurchaseSettings, familySharable: Bool?) async throws {
        _ = try await call {
            try await client.inAppPurchasesV2UpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(familySharable: familySharable, name: changes.referenceName, reviewNote: changes.reviewNote),
                id: id, _type: .inAppPurchases
            ))))).ok
        }
    }

    public func inAppPurchaseLocalizations(purchaseID: String) async throws -> [String: Localized<ProductText>] {
        let localizations = try await all { cursor in
            let page = try await client.inAppPurchasesV2InAppPurchaseLocalizationsGetToManyRelated(.init(path: .init(id: purchaseID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { localization -> Localized<ProductText>? in
                guard let attributes = localization.attributes, let locale = attributes.locale else { return nil }
                return Localized(id: localization.id, locale: locale, text: ProductText(name: attributes.name, description: attributes.description))
            }, page.links.next)
        }
        return Dictionary(localizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func createInAppPurchaseLocalization(purchaseID: String, locale: String, text: ProductText) async throws {
        _ = try await call {
            try await client.inAppPurchaseLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(description: text.description, locale: locale, name: text.name ?? ""),
                relationships: .init(inAppPurchaseV2: .init(data: .init(id: purchaseID, _type: .inAppPurchases))),
                _type: .inAppPurchaseLocalizations
            ))))).created
        }
    }

    public func updateInAppPurchaseLocalization(id: String, _ changes: ProductText) async throws {
        _ = try await call {
            try await client.inAppPurchaseLocalizationsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(description: changes.description, name: changes.name),
                id: id, _type: .inAppPurchaseLocalizations
            ))))).ok
        }
    }

    // MARK: - Availability and price

    public func hasInAppPurchaseAvailability(purchaseID: String) async throws -> Bool {
        do {
            return try await call({
                try await client.inAppPurchasesV2InAppPurchaseAvailabilityGetToOneRelated(.init(path: .init(id: purchaseID))).ok.body.json.data
            }) != nil
        } catch let error as ASCError where error.isNotFound {
            return false
        }
    }

    /// Makes the purchase available in `territories` and every new one.
    public func createInAppPurchaseAvailability(purchaseID: String, territories: [String]) async throws {
        _ = try await call {
            try await client.inAppPurchaseAvailabilitiesCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(availableInNewTerritories: true),
                relationships: .init(
                    availableTerritories: .init(data: territories.map { .init(id: $0, _type: .territories) }),
                    inAppPurchase: .init(data: .init(id: purchaseID, _type: .inAppPurchases))
                ),
                _type: .inAppPurchaseAvailabilities
            ))))).created
        }
    }

    /// The purchase's price points in one territory.
    public func inAppPurchasePricePoints(purchaseID: String, territory: String) async throws -> [PricePoint] {
        try await all { cursor in
            let page = try await client.inAppPurchasesV2PricePointsGetToManyRelated(.init(
                path: .init(id: purchaseID), query: .init(filter_lbrack_territory_rbrack_: [territory], limit: 200, cursor: cursor)
            )).ok.body.json
            return (page.data.map { PricePoint(id: $0.id, customerPrice: $0.attributes?.customerPrice, territory: territory) },
                    page.links.next)
        }
    }

    /// The price the schedule sets by hand in its base territory, from which
    /// App Store Connect equalises every other: the territory and the price
    /// point. Nil before the purchase has a price.
    public func inAppPurchaseBasePrice(purchaseID: String) async throws -> (territory: String, pricePointID: String)? {
        let schedule: String
        do {
            guard let found = try await call({
                try await client.inAppPurchasesV2IapPriceScheduleGetToOneRelated(.init(path: .init(id: purchaseID))).ok.body.json.data
            }) else { return nil }
            schedule = found.id
        } catch let error as ASCError where error.isNotFound {
            return nil
        }
        guard let base = try await call({
            try await client.inAppPurchasePriceSchedulesBaseTerritoryGetToOneRelated(.init(path: .init(id: schedule))).ok.body.json.data
        })?.id else { return nil }
        let prices = try await all { cursor in
            let page = try await client.inAppPurchasePriceSchedulesManualPricesGetToManyRelated(.init(
                path: .init(id: schedule),
                query: .init(filter_lbrack_territory_rbrack_: [base], limit: 50, include: [.inAppPurchasePricePoint, .territory], cursor: cursor)
            )).ok.body.json
            return (page.data, page.links.next)
        }
        guard let point = prices.compactMap({ $0.relationships?.inAppPurchasePricePoint?.data?.id }).first else { return nil }
        return (base, point)
    }

    /// Sets the price in the base territory by hand, which App Store
    /// Connect equalises in every other, replacing the schedule.
    public func setInAppPurchasePrice(purchaseID: String, territory: String, pricePointID: String) async throws {
        _ = try await call {
            try await client.inAppPurchasePriceSchedulesCreateInstance(.init(body: .json(.init(
                data: .init(
                    relationships: .init(
                        baseTerritory: .init(data: .init(id: territory, _type: .territories)),
                        inAppPurchase: .init(data: .init(id: purchaseID, _type: .inAppPurchases)),
                        manualPrices: .init(data: [.init(id: "${price}", _type: .inAppPurchasePrices)])
                    ),
                    _type: .inAppPurchasePriceSchedules
                ),
                included: [.InAppPurchasePriceInlineCreate(.init(
                    id: "${price}",
                    relationships: .init(
                        inAppPurchasePricePoint: .init(data: .init(id: pricePointID, _type: .inAppPurchasePricePoints)),
                        inAppPurchaseV2: .init(data: .init(id: purchaseID, _type: .inAppPurchases))
                    ),
                    _type: .inAppPurchasePrices
                ))]
            )))).created
        }
    }

    // MARK: - App Review screenshot

    public func inAppPurchaseReviewScreenshot(purchaseID: String) async throws -> ProductReviewScreenshot? {
        do {
            guard let screenshot = try await call({
                try await client.inAppPurchasesV2AppStoreReviewScreenshotGetToOneRelated(.init(path: .init(id: purchaseID))).ok.body.json.data
            }) else { return nil }
            return ProductReviewScreenshot(id: screenshot.id, checksum: screenshot.attributes?.sourceFileChecksum)
        } catch let error as ASCError where error.isNotFound {
            return nil
        }
    }

    public func deleteInAppPurchaseReviewScreenshot(id: String) async throws {
        _ = try await call {
            try await client.inAppPurchaseAppStoreReviewScreenshotsDeleteInstance(.init(path: .init(id: id))).noContent
        }
    }

    public func uploadInAppPurchaseReviewScreenshot(purchaseID: String, fileName: String, data: Data) async throws {
        let reservation = try present(try await call {
            try await client.inAppPurchaseAppStoreReviewScreenshotsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(fileName: fileName, fileSize: data.count),
                relationships: .init(inAppPurchaseV2: .init(data: .init(id: purchaseID, _type: .inAppPurchases))),
                _type: .inAppPurchaseAppStoreReviewScreenshots
            ))))).created.body.json.data
        }, "the review screenshot reservation")
        try await transfer(data, operations: reservation.attributes?.uploadOperations ?? [])
        _ = try await call {
            try await client.inAppPurchaseAppStoreReviewScreenshotsUpdateInstance(.init(path: .init(id: reservation.id), body: .json(.init(data: .init(
                attributes: .init(sourceFileChecksum: Self.md5(data), uploaded: true),
                id: reservation.id, _type: .inAppPurchaseAppStoreReviewScreenshots
            ))))).ok
        }
    }
}
