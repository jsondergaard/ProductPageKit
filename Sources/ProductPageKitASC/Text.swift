/// The app-level text of one locale.
public struct AppInfoText: FieldSet {
    public var name: String?
    public var subtitle: String?
    public var privacyPolicyURL: String?

    public init() {}

    public static let properties: [Property<Self>] = [
        Property("name", \.name),
        Property("subtitle", \.subtitle),
        Property("privacyPolicyUrl", \.privacyPolicyURL),
    ]
}

/// The version-level text of one locale.
public struct VersionText: FieldSet {
    public var description: String?
    public var keywords: String?
    public var promotionalText: String?
    public var whatsNew: String?
    public var marketingURL: String?
    public var supportURL: String?

    public init() {}

    public static let properties: [Property<Self>] = [
        Property("description", \.description),
        Property("keywords", \.keywords),
        Property("promotionalText", \.promotionalText),
        Property("whatsNew", \.whatsNew),
        Property("marketingUrl", \.marketingURL),
        Property("supportUrl", \.supportURL),
    ]
}

/// App Review information for one version.
public struct ReviewInfo: FieldSet {
    public var notes: String?
    public var demoAccountRequired: Bool?
    public var demoAccountName: String?
    public var demoAccountPassword: String?
    public var contactFirstName: String?
    public var contactLastName: String?
    public var contactPhone: String?
    public var contactEmail: String?

    public init() {}

    public static let properties: [Property<Self>] = [
        Property("notes", \.notes),
        Property("demoAccountRequired", \.demoAccountRequired),
        Property("demoAccountName", \.demoAccountName),
        Property("demoAccountPassword", \.demoAccountPassword, secret: true),
        Property("contactFirstName", \.contactFirstName),
        Property("contactLastName", \.contactLastName),
        Property("contactPhone", \.contactPhone),
        Property("contactEmail", \.contactEmail),
    ]
}

/// A localization: its id, locale, and text.
public struct Localized<Text: FieldSet>: Equatable, Sendable {
    public let id: String
    public let locale: String
    public let text: Text
}

public struct ReviewDetail: Equatable, Sendable {
    public let id: String
    public let info: ReviewInfo
}

extension AppStoreConnect {
    // MARK: - App info localizations

    /// Keyed by App Store Connect locale.
    public func appInfoLocalizations(appInfoID: String) async throws -> [String: Localized<AppInfoText>] {
        let localizations = try await all { cursor in
            let page = try await client.appInfosAppInfoLocalizationsGetToManyRelated(.init(path: .init(id: appInfoID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { localization -> Localized<AppInfoText>? in
                guard let attributes = localization.attributes, let locale = attributes.locale else { return nil }
                var text = AppInfoText()
                text.name = attributes.name
                text.subtitle = attributes.subtitle
                text.privacyPolicyURL = attributes.privacyPolicyUrl
                return Localized(id: localization.id, locale: locale, text: text)
            }, page.links.next)
        }
        return Dictionary(localizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// App Store Connect refuses an app info localization without a name.
    @discardableResult
    public func createAppInfoLocalization(appInfoID: String, locale: String, name: String, text: AppInfoText) async throws -> String {
        try present(try await call {
            try await client.appInfoLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(locale: locale, name: name, privacyPolicyUrl: text.privacyPolicyURL, subtitle: text.subtitle),
                relationships: .init(appInfo: .init(data: .init(id: appInfoID, _type: .appInfos))),
                _type: .appInfoLocalizations
            ))))).created.body.json.data.id
        }, "the app info localization create")
    }

    public func updateAppInfoLocalization(id: String, _ changes: AppInfoText) async throws {
        _ = try await call {
            try await client.appInfoLocalizationsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(name: changes.name, privacyPolicyUrl: changes.privacyPolicyURL, subtitle: changes.subtitle),
                id: id, _type: .appInfoLocalizations
            ))))).ok
        }
    }

    // MARK: - Version localizations

    /// Keyed by App Store Connect locale.
    public func versionLocalizations(versionID: String) async throws -> [String: Localized<VersionText>] {
        let localizations = try await all { cursor in
            let page = try await client.appStoreVersionsAppStoreVersionLocalizationsGetToManyRelated(.init(path: .init(id: versionID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { localization -> Localized<VersionText>? in
                guard let attributes = localization.attributes, let locale = attributes.locale else { return nil }
                var text = VersionText()
                text.description = attributes.description
                text.keywords = attributes.keywords
                text.promotionalText = attributes.promotionalText
                text.whatsNew = attributes.whatsNew
                text.marketingURL = attributes.marketingUrl
                text.supportURL = attributes.supportUrl
                return Localized(id: localization.id, locale: locale, text: text)
            }, page.links.next)
        }
        return Dictionary(localizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @discardableResult
    public func createVersionLocalization(versionID: String, locale: String, text: VersionText) async throws -> String {
        try present(try await call {
            try await client.appStoreVersionLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(
                    description: text.description, keywords: text.keywords, locale: locale,
                    marketingUrl: text.marketingURL, promotionalText: text.promotionalText,
                    supportUrl: text.supportURL, whatsNew: text.whatsNew
                ),
                relationships: .init(appStoreVersion: .init(data: .init(id: versionID, _type: .appStoreVersions))),
                _type: .appStoreVersionLocalizations
            ))))).created.body.json.data.id
        }, "the version localization create")
    }

    public func updateVersionLocalization(id: String, _ changes: VersionText) async throws {
        _ = try await call {
            try await client.appStoreVersionLocalizationsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(
                    description: changes.description, keywords: changes.keywords, marketingUrl: changes.marketingURL,
                    promotionalText: changes.promotionalText, supportUrl: changes.supportURL, whatsNew: changes.whatsNew
                ),
                id: id, _type: .appStoreVersionLocalizations
            ))))).ok
        }
    }

    // MARK: - App Review details

    /// The version's App Review information, or nil before it has any.
    public func reviewDetail(versionID: String) async throws -> ReviewDetail? {
        do {
            guard let detail = try await call({
                try await client.appStoreVersionsAppStoreReviewDetailGetToOneRelated(.init(path: .init(id: versionID))).ok.body.json.data
            }) else { return nil }
            let attributes = detail.attributes
            var info = ReviewInfo()
            info.notes = attributes?.notes
            info.demoAccountRequired = attributes?.demoAccountRequired
            info.demoAccountName = attributes?.demoAccountName
            info.demoAccountPassword = attributes?.demoAccountPassword
            info.contactFirstName = attributes?.contactFirstName
            info.contactLastName = attributes?.contactLastName
            info.contactPhone = attributes?.contactPhone
            info.contactEmail = attributes?.contactEmail
            return ReviewDetail(id: detail.id, info: info)
        } catch let error as ASCError where error.isNotFound {
            return nil
        }
    }

    public func createReviewDetail(versionID: String, _ info: ReviewInfo) async throws {
        _ = try await call {
            try await client.appStoreReviewDetailsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(
                    contactEmail: info.contactEmail, contactFirstName: info.contactFirstName,
                    contactLastName: info.contactLastName, contactPhone: info.contactPhone,
                    demoAccountName: info.demoAccountName, demoAccountPassword: info.demoAccountPassword,
                    demoAccountRequired: info.demoAccountRequired, notes: info.notes
                ),
                relationships: .init(appStoreVersion: .init(data: .init(id: versionID, _type: .appStoreVersions))),
                _type: .appStoreReviewDetails
            ))))).created
        }
    }

    public func updateReviewDetail(id: String, _ changes: ReviewInfo) async throws {
        _ = try await call {
            try await client.appStoreReviewDetailsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(
                    contactEmail: changes.contactEmail, contactFirstName: changes.contactFirstName,
                    contactLastName: changes.contactLastName, contactPhone: changes.contactPhone,
                    demoAccountName: changes.demoAccountName, demoAccountPassword: changes.demoAccountPassword,
                    demoAccountRequired: changes.demoAccountRequired, notes: changes.notes
                ),
                id: id, _type: .appStoreReviewDetails
            ))))).ok
        }
    }
}
