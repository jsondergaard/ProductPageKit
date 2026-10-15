public import ProductPageKitCore

public struct App: Equatable, Sendable {
    public let id: String
    public let name: String
    public let notifications: ServerNotifications
}

/// Where App Store Server Notifications go, production and sandbox.
public struct ServerNotifications: FieldSet {
    public var url: String?
    public var version: String?
    public var sandboxURL: String?
    public var sandboxVersion: String?

    public init() {}

    public init(url: String?, version: String?, sandboxURL: String?, sandboxVersion: String?) {
        self.url = url
        self.version = version
        self.sandboxURL = sandboxURL
        self.sandboxVersion = sandboxVersion
    }

    public static let properties: [Property<Self>] = [
        Property("subscriptionStatusUrl", \.url),
        Property("subscriptionStatusUrlVersion", \.version),
        Property("subscriptionStatusUrlForSandbox", \.sandboxURL),
        Property("subscriptionStatusUrlVersionForSandbox", \.sandboxVersion),
    ]
}

public struct AppInfo: Equatable, Sendable {
    public let id: String
    public let state: String?
}

/// A version of the app on one App Store platform.
public struct AppVersion: Equatable, Sendable {
    public let id: String
    public let platform: StorePlatform
    public let versionString: String
    public let state: String
    public let copyright: String?

    /// Whether App Store Connect still takes metadata changes on it.
    public var isEditable: Bool { AppStoreConnect.editableStates.contains(state) }
}

public struct AppNotFound: Error, CustomStringConvertible {
    public let bundleID: String
    public var description: String { "No app with bundle id \(bundleID) is visible to this API key." }
}

extension AppStoreConnect {
    /// States in which App Store Connect accepts metadata edits.
    public static let editableStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
        "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY",
    ]

    public func app(bundleID: String) async throws -> App {
        let response = try await call {
            try await client.appsGetCollection(.init(query: .init(filter_lbrack_bundleId_rbrack_: [bundleID]))).ok.body.json
        }
        guard let app = response.data.first else { throw AppNotFound(bundleID: bundleID) }
        let attributes = app.attributes
        return App(
            id: app.id,
            name: attributes?.name ?? bundleID,
            notifications: ServerNotifications(
                url: attributes?.subscriptionStatusUrl,
                version: attributes?.subscriptionStatusUrlVersion,
                sandboxURL: attributes?.subscriptionStatusUrlForSandbox,
                sandboxVersion: attributes?.subscriptionStatusUrlVersionForSandbox
            )
        )
    }

    public func updateNotifications(appID: String, _ changes: ServerNotifications) async throws {
        _ = try await call {
            try await client.appsUpdateInstance(.init(path: .init(id: appID), body: .json(.init(data: .init(
                attributes: .init(
                    subscriptionStatusUrl: changes.url,
                    subscriptionStatusUrlForSandbox: changes.sandboxURL,
                    subscriptionStatusUrlVersion: changes.version,
                    subscriptionStatusUrlVersionForSandbox: changes.sandboxVersion
                ),
                id: appID, _type: .apps
            ))))).ok
        }
    }

    /// The app info App Store Connect takes name and subtitle changes on: the
    /// editable one, or else the first.
    public func appInfo(appID: String) async throws -> AppInfo? {
        let infos = try await all { cursor in
            let page = try await client.appsAppInfosGetToManyRelated(.init(path: .init(id: appID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.map { AppInfo(id: $0.id, state: $0.attributes?.appStoreState) }, page.links.next)
        }
        return infos.first { Self.editableStates.contains($0.state ?? "") } ?? infos.first
    }

    /// Every version of the app, newest first.
    public func versions(appID: String) async throws -> [AppVersion] {
        try await all { cursor in
            let page = try await client.appsAppStoreVersionsGetToManyRelated(.init(path: .init(id: appID), query: .init(limit: 50, cursor: cursor))).ok.body.json
            return (page.data.compactMap { version in
                let attributes = version.attributes
                guard let platform = attributes?.platform.flatMap(StorePlatform.init(rawValue:)) else { return nil }
                return AppVersion(id: version.id, platform: platform, versionString: attributes?.versionString ?? "",
                                  state: attributes?.appStoreState ?? "", copyright: attributes?.copyright)
            }, page.links.next)
        }
    }

    /// The newest editable version on each App Store platform.
    public func editableVersions(appID: String) async throws -> [StorePlatform: AppVersion] {
        var editable: [StorePlatform: AppVersion] = [:]
        for version in try await versions(appID: appID) where version.isEditable && editable[version.platform] == nil {
            editable[version.platform] = version
        }
        return editable
    }

    public func updateCopyright(versionID: String, _ copyright: String) async throws {
        _ = try await call {
            try await client.appStoreVersionsUpdateInstance(.init(path: .init(id: versionID), body: .json(.init(data: .init(
                attributes: .init(copyright: copyright), id: versionID, _type: .appStoreVersions
            ))))).ok
        }
    }
}
