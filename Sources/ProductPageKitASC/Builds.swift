public import Foundation
public import ProductPageKitCore

/// An upload of the app, as TestFlight lists it.
public struct Build: Equatable, Sendable {
    public let id: String
    /// Its `CFBundleVersion`, as uploaded.
    public let number: String
    /// Its `CFBundleShortVersionString`.
    public let version: String?
    public let platform: StorePlatform?
    public let uploaded: Date?
    /// `PROCESSING`, `FAILED`, `INVALID` or `VALID`.
    public let processingState: String?
    /// `INTERNAL_ONLY` or `APP_STORE_ELIGIBLE`.
    public let audience: String?
    public let expired: Bool

    public init(id: String, number: String, version: String?, platform: StorePlatform?, uploaded: Date?,
                processingState: String?, audience: String?, expired: Bool) {
        self.id = id
        self.number = number
        self.version = version
        self.platform = platform
        self.uploaded = uploaded
        self.processingState = processingState
        self.audience = audience
        self.expired = expired
    }
}

extension AppStoreConnect {
    /// Every build of the app, expired ones too, most recently uploaded first.
    public func builds(appID: String) async throws -> [Build] {
        try await all { cursor in
            let page = try await client.buildsGetCollection(.init(query: .init(
                filter_lbrack_app_rbrack_: [appID],
                sort: [._hyphen_uploadedDate],
                fields_lbrack_builds_rbrack_: [.version, .uploadedDate, .expired, .processingState, .buildAudienceType, .preReleaseVersion],
                fields_lbrack_preReleaseVersions_rbrack_: [.version, .platform],
                limit: 200,
                include: [.preReleaseVersion],
                cursor: cursor
            ))).ok.body.json
            let versions = Dictionary((page.included ?? []).compactMap { included -> (String, (String?, StorePlatform?))? in
                guard case .preReleaseVersions(let version) = included else { return nil }
                return (version.id, (version.attributes?.version, version.attributes?.platform.flatMap(StorePlatform.init(rawValue:))))
            }, uniquingKeysWith: { first, _ in first })
            return (page.data.map { build in
                let attributes = build.attributes
                let version = build.relationships?.preReleaseVersion?.data.flatMap { versions[$0.id] }
                return Build(id: build.id, number: attributes?.version ?? "", version: version?.0 ?? nil,
                             platform: version?.1 ?? nil, uploaded: attributes?.uploadedDate,
                             processingState: attributes?.processingState, audience: attributes?.buildAudienceType,
                             expired: attributes?.expired ?? false)
            }, page.links.next)
        }
    }
}
