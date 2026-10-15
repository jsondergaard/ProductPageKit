public import Foundation
import CryptoKit

/// Writes the local StoreKit configuration file from the product catalogue,
/// so Debug runs and tests buy exactly what App Store Connect sells.
///
/// The file's own ids (its identifier, each group's id, each product's
/// `internalID`) never leave the machine. They are kept from the file being
/// replaced, so rewriting the same catalogue changes nothing, and derived
/// from the bundle id for anything new.
public enum StoreKitConfiguration {
    public static func data(catalogue: ProductCatalogue, project: Project, existing: Data?) throws -> Data {
        guard let products = project.products, let file = products.storeKit else {
            throw StoreKitConfigurationError.notConfigured
        }
        let previous = existing.flatMap { try? JSONDecoder().decode(ExistingIDs.self, from: $0) }
        let seed = Array(SHA256.hash(data: Data(project.bundleID.utf8)))
        var ids = IDs(previous: previous, seed: seed)
        let locales = project.locales

        let groups = catalogue.subscriptionGroups.map { group in
            let groupID = ids.group(group.referenceName)
            return Group(
                id: groupID,
                localizations: locales.compactMap { locale in
                    group.localizations[locale.code].map { GroupLocalization(displayName: $0.name, locale: locale.localeIdentifier) }
                },
                name: group.referenceName,
                subscriptions: group.subscriptions.map { subscription in
                    Product(
                        displayPrice: subscription.price,
                        familyShareable: subscription.familySharable,
                        groupNumber: subscription.level,
                        internalID: ids.product(subscription.productID),
                        localizations: locales.compactMap { locale in
                            subscription.localizations[locale.code].map {
                                Localization(description: $0.description, displayName: $0.name, locale: locale.localeIdentifier)
                            }
                        },
                        productID: subscription.productID,
                        recurringSubscriptionPeriod: subscription.period.rawValue,
                        referenceName: subscription.referenceName,
                        subscriptionGroupID: groupID
                    )
                }
            )
        }
        let purchases = catalogue.inAppPurchases.map { purchase in
            OneTimeProduct(
                displayPrice: purchase.price,
                familyShareable: purchase.familySharable,
                internalID: ids.product(purchase.productID),
                localizations: locales.compactMap { locale in
                    purchase.localizations[locale.code].map {
                        Localization(description: $0.description, displayName: $0.name, locale: locale.localeIdentifier)
                    }
                },
                productID: purchase.productID,
                referenceName: purchase.referenceName,
                type: purchase.kind
            )
        }
        let configuration = File(
            identifier: ids.identifier,
            nonRenewingSubscriptions: purchases.filter { $0.type == .nonRenewingSubscription },
            products: purchases.filter { $0.type != .nonRenewingSubscription },
            settings: Settings(developerTeamID: file.teamID, locale: project.primaryLocale.localeIdentifier,
                               storefront: products.baseTerritory),
            subscriptionGroups: groups
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(configuration) + Data("\n".utf8)
    }

    /// Writes the file at `StoreKitFile.path`. Returns whether it changed.
    public static func write(catalogue: ProductCatalogue, project: Project, root: URL) throws -> Bool {
        guard let path = project.products?.storeKit?.path else { throw StoreKitConfigurationError.notConfigured }
        let url = root.appending(path: path)
        let existing = try? Data(contentsOf: url)
        let data = try data(catalogue: catalogue, project: project, existing: existing)
        guard data != existing else { return false }
        try data.write(to: url, options: .atomic)
        return true
    }

    /// The file's ids: the previous file's where it has them, else new ones
    /// derived from the bundle id.
    private struct IDs {
        let identifier: String
        private var groups: [String: String]
        private var products: [String: String]
        private var nextGroup: Int
        private var nextProduct: Int

        init(previous: ExistingIDs?, seed: [UInt8]) {
            identifier = previous?.identifier ?? seed.prefix(4).map { String(format: "%02X", $0) }.joined()
            let previousGroups = previous?.subscriptionGroups ?? []
            groups = Dictionary(previousGroups.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
            let previousProducts = previousGroups.flatMap(\.subscriptions) + (previous?.products ?? [])
                + (previous?.nonRenewingSubscriptions ?? [])
            products = Dictionary(previousProducts.map { ($0.productID, $0.internalID) }, uniquingKeysWith: { first, _ in first })
            nextGroup = (groups.values.compactMap(Int.init).max() ?? 10_000_000 + (Int(seed[4]) << 16 | Int(seed[5]) << 8 | Int(seed[6]))) + 1
            nextProduct = (products.values.compactMap(Int.init).max() ?? 6_000_000_000 + Int(seed[7]) * 1_000_000) + 1
        }

        mutating func group(_ name: String) -> String {
            if let id = groups[name] { return id }
            defer { nextGroup += 1 }
            groups[name] = String(nextGroup)
            return String(nextGroup)
        }

        mutating func product(_ productID: String) -> String {
            if let id = products[productID] { return id }
            defer { nextProduct += 1 }
            products[productID] = String(nextProduct)
            return String(nextProduct)
        }
    }

    // MARK: - The file's format

    private struct ExistingIDs: Decodable {
        struct Product: Decodable {
            let internalID: String
            let productID: String
        }
        struct Group: Decodable {
            let id: String
            let name: String
            let subscriptions: [Product]
        }
        let identifier: String
        let subscriptionGroups: [Group]
        let products: [Product]?
        let nonRenewingSubscriptions: [Product]?
    }

    private struct File: Encodable {
        let identifier: String
        let nonRenewingSubscriptions: [OneTimeProduct]
        let products: [OneTimeProduct]
        let settings: Settings
        let subscriptionGroups: [Group]
        let version = Version()
    }

    /// A product bought once, or a non-renewing subscription.
    private struct OneTimeProduct: Encodable {
        let displayPrice: String
        let familyShareable: Bool
        let internalID: String
        let localizations: [Localization]
        let productID: String
        let referenceName: String
        let type: ProductCatalogue.InAppPurchase.Kind

        enum CodingKeys: String, CodingKey {
            case displayPrice, familyShareable, internalID, localizations, productID, referenceName, type
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(displayPrice, forKey: .displayPrice)
            try container.encode(familyShareable, forKey: .familyShareable)
            try container.encode(internalID, forKey: .internalID)
            try container.encode(localizations, forKey: .localizations)
            try container.encode(productID, forKey: .productID)
            try container.encode(referenceName, forKey: .referenceName)
            // StoreKit's own names for the kinds.
            let names: [ProductCatalogue.InAppPurchase.Kind: String] = [
                .consumable: "Consumable", .nonConsumable: "NonConsumable", .nonRenewingSubscription: "NonRenewingSubscription",
            ]
            try container.encode(names[type]!, forKey: .type)
        }
    }

    private struct Version: Encodable {
        let major = 4
        let minor = 0
    }

    private struct Settings: Encodable {
        let developerTeamID: String
        let failTransactionsEnabled = false
        let locale: String
        let storefront: String
        let storeKitErrors: [String] = []

        enum CodingKeys: String, CodingKey {
            case developerTeamID = "_developerTeamID"
            case failTransactionsEnabled = "_failTransactionsEnabled"
            case locale = "_locale"
            case storefront = "_storefront"
            case storeKitErrors = "_storeKitErrors"
        }
    }

    private struct Group: Encodable {
        let id: String
        let localizations: [GroupLocalization]
        let name: String
        let subscriptions: [Product]
    }

    private struct GroupLocalization: Encodable {
        let customAppName = ""
        let displayName: String
        let locale: String
    }

    private struct Localization: Encodable {
        let description: String
        let displayName: String
        let locale: String
    }

    private struct Product: Encodable {
        let displayPrice: String
        let familyShareable: Bool
        let groupNumber: Int
        let internalID: String
        let localizations: [Localization]
        let productID: String
        let recurringSubscriptionPeriod: String
        let referenceName: String
        let subscriptionGroupID: String

        enum CodingKeys: String, CodingKey {
            case adHocOffers, codeOffers, displayPrice, familyShareable, groupNumber, internalID
            case introductoryOffer, localizations, productID, recurringSubscriptionPeriod
            case referenceName, subscriptionGroupID, type, winbackOffers
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode([String](), forKey: .adHocOffers)
            try container.encode([String](), forKey: .codeOffers)
            try container.encode(displayPrice, forKey: .displayPrice)
            try container.encode(familyShareable, forKey: .familyShareable)
            try container.encode(groupNumber, forKey: .groupNumber)
            try container.encode(internalID, forKey: .internalID)
            try container.encodeNil(forKey: .introductoryOffer)
            try container.encode(localizations, forKey: .localizations)
            try container.encode(productID, forKey: .productID)
            try container.encode(recurringSubscriptionPeriod, forKey: .recurringSubscriptionPeriod)
            try container.encode(referenceName, forKey: .referenceName)
            try container.encode(subscriptionGroupID, forKey: .subscriptionGroupID)
            try container.encode("RecurringSubscription", forKey: .type)
            try container.encode([String](), forKey: .winbackOffers)
        }
    }
}

public enum StoreKitConfigurationError: Error, CustomStringConvertible {
    case notConfigured

    public var description: String {
        "The project has no StoreKit configuration file (Products.storeKit)."
    }
}
