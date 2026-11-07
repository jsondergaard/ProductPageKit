public import Foundation
public import ProductPageKitCore

/// One open edit of an app's listing. What it changes stays in the edit
/// until `commit`, and `delete` throws it all away.
public struct PlayEdit: Sendable {
    let api: GooglePlayAPI
    public let packageName: String
    public let id: String

    private var path: String { "/androidpublisher/v3/applications/\(packageName)/edits/\(id)" }

    /// The language a listing falls back to where it has no translation.
    public func defaultLanguage() async throws -> String? {
        struct Details: Decodable { let defaultLanguage: String? }
        let details: Details = try await api.call(.get, path + "/details")
        return details.defaultLanguage
    }

    /// Every language's listing text.
    public func listings() async throws -> [PlayListing] {
        struct Page: Decodable { let listings: [PlayListing]? }
        let page: Page = try await api.call(.get, path + "/listings")
        return page.listings ?? []
    }

    /// Writes the whole of a language's listing, creating it if it has none.
    public func putListing(_ listing: PlayListing) async throws {
        let _: PlayListing = try await api.call(.put, path + "/listings/\(listing.language)", json: try JSONEncoder().encode(listing))
    }

    /// Writes the fields `text` holds of an existing language's listing,
    /// leaving the others as they are.
    public func patchListing(language: String, _ text: PlayListing.Text) async throws {
        let _: PlayListing = try await api.call(.patch, path + "/listings/\(language)", json: try JSONEncoder().encode(text))
    }

    /// A slot's images in one language, in the order the listing shows them.
    public func images(language: String, type: PlayImageType) async throws -> [PlayImage] {
        struct Page: Decodable { let images: [PlayImage]? }
        let page: Page = try await api.call(.get, path + "/listings/\(language)/\(type.rawValue)")
        return page.images ?? []
    }

    /// Adds an image at the end of a slot.
    @discardableResult
    public func upload(_ data: Data, contentType: String, language: String, type: PlayImageType) async throws -> PlayImage {
        struct Uploaded: Decodable { let image: PlayImage }
        let uploaded: Uploaded = try await api.call(.post, "/upload" + path + "/listings/\(language)/\(type.rawValue)",
                                                    query: "uploadType=media", upload: (data, contentType))
        return uploaded.image
    }

    public func deleteImage(_ image: PlayImage, language: String, type: PlayImageType) async throws {
        try await api.perform(.delete, path + "/listings/\(language)/\(type.rawValue)/\(image.id)")
    }

    /// Every track and its releases.
    public func tracks() async throws -> [PlayTrack] {
        struct Page: Decodable { let tracks: [PlayTrack]? }
        let page: Page = try await api.call(.get, path + "/tracks")
        return page.tracks ?? []
    }

    /// Makes the edit's changes live, or, without `sendForReview`, leaves
    /// them for sending for review from the Play Console.
    public func commit(sendForReview: Bool) async throws {
        struct Committed: Decodable {}
        let _: Committed = try await api.call(.post, path + ":commit", query: sendForReview ? nil : "changesNotSentForReview=true")
    }

    /// Throws the edit away with everything it changed.
    public func delete() async throws {
        try await api.perform(.delete, path)
    }
}

/// A language's listing text.
public struct PlayListing: Codable, Equatable, Sendable {
    public var language: String
    public var title: String?
    public var shortDescription: String?
    public var fullDescription: String?

    public init(language: String, title: String?, shortDescription: String?, fullDescription: String?) {
        self.language = language
        self.title = title
        self.shortDescription = shortDescription
        self.fullDescription = fullDescription
    }

    /// The fields a patch writes; those left nil are left as they are.
    public struct Text: Codable, Equatable, Sendable {
        public var title: String?
        public var shortDescription: String?
        public var fullDescription: String?

        public init(title: String? = nil, shortDescription: String? = nil, fullDescription: String? = nil) {
            self.title = title
            self.shortDescription = shortDescription
            self.fullDescription = fullDescription
        }
    }
}

/// An image a listing holds.
public struct PlayImage: Codable, Equatable, Sendable {
    public let id: String
    /// Hex SHA-256 of the file as uploaded, which is how a local file is
    /// matched to it.
    public let sha256: String?

    public init(id: String, sha256: String?) {
        self.id = id
        self.sha256 = sha256
    }
}

/// A release track and what it holds.
public struct PlayTrack: Codable, Equatable, Sendable {
    public struct Release: Codable, Equatable, Sendable {
        public let name: String?
        public let versionCodes: [String]?
        /// `draft`, `inProgress`, `halted` or `completed`.
        public let status: String?
        public let userFraction: Double?

        public init(name: String?, versionCodes: [String]?, status: String?, userFraction: Double?) {
            self.name = name
            self.versionCodes = versionCodes
            self.status = status
            self.userFraction = userFraction
        }
    }

    public let track: String
    public let releases: [Release]?

    public init(track: String, releases: [Release]?) {
        self.track = track
        self.releases = releases
    }
}
