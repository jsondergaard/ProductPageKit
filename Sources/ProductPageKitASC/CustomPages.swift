import Foundation
import OpenAPIRuntime

/// A custom product page App Store Connect holds.
public struct CustomPageRecord: Equatable, Sendable {
    public let id: String
    public let name: String
    public let isVisible: Bool
    public let url: String?
}

/// One version of a custom product page's content.
public struct CustomPageVersion: Equatable, Sendable {
    public let id: String
    public let version: String?
    public let state: String?

    /// Once App Review approves a version it is frozen; changing the page
    /// means a new version, which serves only once it is approved in turn.
    public var isEditable: Bool { Self.editableStates.contains(state ?? "") }

    public static let editableStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED"]
}

/// A custom product page version's text in one locale.
public struct CustomPageLocalization: Equatable, Sendable {
    public let id: String
    public let locale: String
    public let promotionalText: String?
}

extension AppStoreConnect {
    public func customPages(appID: String) async throws -> [CustomPageRecord] {
        try await all { cursor in
            let page = try await client.appsAppCustomProductPagesGetToManyRelated(
                .init(path: .init(id: appID), query: .init(limit: 50, cursor: cursor))
            ).ok.body.json
            return (page.data.map { record in
                CustomPageRecord(id: record.id, name: record.attributes?.name ?? "", isVisible: record.attributes?.visible ?? false,
                                 url: record.attributes?.url)
            }, page.links.next)
        }
    }

    /// Creates a page with its first version and one localization, in one
    /// request: App Store Connect refuses a page without them. Returns the
    /// page's id.
    public func createCustomPage(appID: String, name: String, locale: String, promotionalText: String?) async throws -> String {
        try await call {
            try await client.appCustomProductPagesCreateInstance(.init(body: .json(.init(
                data: .init(
                    attributes: .init(name: name),
                    relationships: .init(
                        app: .init(data: .init(id: appID, _type: .apps)),
                        appCustomProductPageVersions: .init(data: [.init(id: "${version}", _type: .appCustomProductPageVersions)])
                    ),
                    _type: .appCustomProductPages
                ),
                included: [
                    .AppCustomProductPageVersionInlineCreate(.init(id: "${version}", relationships: .init(
                        appCustomProductPageLocalizations: .init(data: [.init(id: "${localization}", _type: .appCustomProductPageLocalizations)])
                    ), _type: .appCustomProductPageVersions)),
                    .AppCustomProductPageLocalizationInlineCreate(.init(
                        attributes: .init(locale: locale, promotionalText: promotionalText), id: "${localization}",
                        _type: .appCustomProductPageLocalizations
                    )),
                ]
            )))).created.body.json.data.id
        }
    }

    /// A page App Store Connect keeps hidden opens nowhere a link sends it.
    public func showCustomPage(id: String) async throws {
        _ = try await call {
            try await client.appCustomProductPagesUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(visible: true), id: id, _type: .appCustomProductPages
            ))))).ok
        }
    }

    /// Every version of the page, oldest first.
    public func customPageVersions(pageID: String) async throws -> [CustomPageVersion] {
        let versions = try await all { cursor in
            let page = try await client.appCustomProductPagesAppCustomProductPageVersionsGetToManyRelated(
                .init(path: .init(id: pageID), query: .init(limit: 50, cursor: cursor))
            ).ok.body.json
            return (page.data.map { CustomPageVersion(id: $0.id, version: $0.attributes?.version, state: $0.attributes?.state) },
                    page.links.next)
        }
        return versions.sorted { ($0.version ?? "").compare($1.version ?? "", options: .numeric) == .orderedAscending }
    }

    /// A new version of the page, holding a copy of the newest one's
    /// content. Returns its id.
    public func createCustomPageVersion(pageID: String) async throws -> String {
        try await call {
            try await client.appCustomProductPageVersionsCreateInstance(.init(body: .json(.init(data: .init(
                relationships: .init(appCustomProductPage: .init(data: .init(id: pageID, _type: .appCustomProductPages))),
                _type: .appCustomProductPageVersions
            ))))).created.body.json.data.id
        }
    }

    /// The version's localizations, by App Store Connect locale.
    public func customPageLocalizations(versionID: String) async throws -> [String: CustomPageLocalization] {
        let localizations = try await all { cursor in
            let page = try await client.appCustomProductPageVersionsAppCustomProductPageLocalizationsGetToManyRelated(
                .init(path: .init(id: versionID), query: .init(limit: 50, cursor: cursor))
            ).ok.body.json
            return (page.data.map {
                CustomPageLocalization(id: $0.id, locale: $0.attributes?.locale ?? "", promotionalText: $0.attributes?.promotionalText)
            }, page.links.next)
        }
        return Dictionary(localizations.map { ($0.locale, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func createCustomPageLocalization(versionID: String, locale: String, promotionalText: String?) async throws -> String {
        try await call {
            try await client.appCustomProductPageLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(locale: locale, promotionalText: promotionalText),
                relationships: .init(appCustomProductPageVersion: .init(data: .init(id: versionID, _type: .appCustomProductPageVersions))),
                _type: .appCustomProductPageLocalizations
            ))))).created.body.json.data.id
        }
    }

    public func updateCustomPageLocalization(id: String, promotionalText: String) async throws {
        _ = try await call {
            try await client.appCustomProductPageLocalizationsUpdateInstance(.init(path: .init(id: id), body: .json(.init(data: .init(
                attributes: .init(promotionalText: promotionalText), id: id, _type: .appCustomProductPageLocalizations
            ))))).ok
        }
    }

    /// The terms a custom page can be assigned in `locale`: the keywords of
    /// the app's live version on `platform`.
    public func searchKeywords(appID: String, locale: String, platform: String) async throws -> Set<String> {
        Set(try await all { cursor in
            let page = try await client.appsSearchKeywordsGetToManyRelated(.init(path: .init(id: appID), query: .init(
                filter_lbrack_platform_rbrack_: [platform], filter_lbrack_locale_rbrack_: [locale], limit: 200, cursor: cursor
            ))).ok.body.json
            return (page.data.map(\.id), page.links.next)
        })
    }

    /// The terms assigned to a custom page's localization.
    public func assignedKeywords(localizationID: String) async throws -> Set<String> {
        Set(try await all { cursor in
            let page = try await client.appCustomProductPageLocalizationsSearchKeywordsGetToManyRelationship(
                .init(path: .init(id: localizationID), query: .init(limit: 200, cursor: cursor))
            ).ok.body.json
            return (page.data.map(\.id), page.links.next)
        })
    }

    public func assignKeywords(_ keywords: [String], localizationID: String) async throws {
        _ = try await call {
            try await client.appCustomProductPageLocalizationsSearchKeywordsCreateToManyRelationship(.init(
                path: .init(id: localizationID),
                body: .json(.init(data: keywords.map { .init(id: $0, _type: .appKeywords) }))
            )).noContent
        }
    }

    public func unassignKeywords(_ keywords: [String], localizationID: String) async throws {
        _ = try await call {
            try await client.appCustomProductPageLocalizationsSearchKeywordsDeleteToManyRelationship(.init(
                path: .init(id: localizationID),
                body: .json(.init(data: keywords.map { .init(id: $0, _type: .appKeywords) }))
            )).noContent
        }
    }
}
