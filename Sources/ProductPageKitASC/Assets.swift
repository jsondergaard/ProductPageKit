import CryptoKit
public import Foundation
import HTTPTypes
import OpenAPIRuntime
import ProductPageKitCore

/// A screenshot App Store Connect holds.
public struct Screenshot: Hashable, Sendable {
    public let id: String
    /// MD5 of the uploaded file, which is how an unchanged file is recognised.
    public let checksum: String?
    /// App Store Connect's processing state: `COMPLETE`, `FAILED`, and the
    /// states in between.
    public let state: String?
}

/// A video in the app's asset library.
public struct LibraryVideo: Hashable, Sendable {
    public let id: String
    public let referenceName: String?
    public let state: String
    public let stateDetails: [String]
}

/// The localization a screenshot set belongs to: a version's, a custom
/// product page's, or an experiment treatment's.
public enum ScreenshotSetOwner: Hashable, Sendable {
    case version(String)
    case customPage(String)
    case treatment(String)
}

/// Something placed in a product page slot.
public struct Placement: Hashable, Sendable {
    public let id: String
    public let placementType: String
}

extension AppStoreConnect {
    // MARK: - Screenshots

    /// The localization's screenshot sets, by display type.
    ///
    /// Several device sets share one localization, so the display type is
    /// read from each returned set rather than trusted to a server filter: an
    /// unapplied filter would hand back the Mac set to a caller replacing the
    /// iPhone one.
    public func screenshotSets(_ owner: ScreenshotSetOwner) async throws -> [String: String] {
        let sets: [(type: String?, id: String)] = switch owner {
        case .version(let id):
            try await all { cursor in
                let page = try await client.appStoreVersionLocalizationsAppScreenshotSetsGetToManyRelated(
                    .init(path: .init(id: id), query: .init(limit: 50, cursor: cursor))
                ).ok.body.json
                return (page.data.map { ($0.attributes?.screenshotDisplayType, $0.id) }, page.links.next)
            }
        case .customPage(let id):
            try await all { cursor in
                let page = try await client.appCustomProductPageLocalizationsAppScreenshotSetsGetToManyRelated(
                    .init(path: .init(id: id), query: .init(limit: 50, cursor: cursor))
                ).ok.body.json
                return (page.data.map { ($0.attributes?.screenshotDisplayType, $0.id) }, page.links.next)
            }
        case .treatment(let id):
            try await all { cursor in
                let page = try await client.appStoreVersionExperimentTreatmentLocalizationsAppScreenshotSetsGetToManyRelated(
                    .init(path: .init(id: id), query: .init(limit: 50, cursor: cursor))
                ).ok.body.json
                return (page.data.map { ($0.attributes?.screenshotDisplayType, $0.id) }, page.links.next)
            }
        }
        return Dictionary(sets.compactMap { set in set.type.map { ($0, set.id) } }, uniquingKeysWith: { first, _ in first })
    }

    public func createScreenshotSet(_ owner: ScreenshotSetOwner, displayType: String) async throws -> String {
        let relationships: Components.Schemas.AppScreenshotSetCreateRequest.DataPayload.RelationshipsPayload = switch owner {
        case .version(let id):
            .init(appStoreVersionLocalization: .init(data: .init(id: id, _type: .appStoreVersionLocalizations)))
        case .customPage(let id):
            .init(appCustomProductPageLocalization: .init(data: .init(id: id, _type: .appCustomProductPageLocalizations)))
        case .treatment(let id):
            .init(appStoreVersionExperimentTreatmentLocalization: .init(data: .init(
                id: id, _type: .appStoreVersionExperimentTreatmentLocalizations
            )))
        }
        return try await call {
            try await client.appScreenshotSetsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(screenshotDisplayType: displayType), relationships: relationships, _type: .appScreenshotSets
            ))))).created.body.json.data.id
        }
    }

    /// The set's screenshots, in display order.
    public func screenshots(setID: String) async throws -> [Screenshot] {
        let screenshots = try await all { cursor in
            let page = try await client.appScreenshotSetsAppScreenshotsGetToManyRelated(
                .init(path: .init(id: setID), query: .init(limit: 50, cursor: cursor))
            ).ok.body.json
            return (page.data, page.links.next)
        }
        return screenshots.map {
            Screenshot(id: $0.id, checksum: $0.attributes?.sourceFileChecksum, state: $0.attributes?.assetDeliveryState?.state)
        }
    }

    /// Reserves, uploads and commits one screenshot into a set. Returns its id.
    @discardableResult
    public func uploadScreenshot(setID: String, fileName: String, data: Data) async throws -> String {
        let reservation = try await call {
            try await client.appScreenshotsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(fileName: fileName, fileSize: data.count),
                relationships: .init(appScreenshotSet: .init(data: .init(id: setID, _type: .appScreenshotSets))),
                _type: .appScreenshots
            ))))).created.body.json.data
        }
        try await transfer(data, operations: reservation.attributes?.uploadOperations ?? [])
        _ = try await call {
            try await client.appScreenshotsUpdateInstance(.init(path: .init(id: reservation.id), body: .json(.init(data: .init(
                attributes: .init(sourceFileChecksum: Self.md5(data), uploaded: true),
                id: reservation.id, _type: .appScreenshots
            ))))).ok
        }
        return reservation.id
    }

    public func deleteScreenshot(id: String) async throws {
        _ = try await call { try await client.appScreenshotsDeleteInstance(.init(path: .init(id: id))).noContent }
    }

    /// Puts the set's screenshots in this order.
    public func orderScreenshots(setID: String, ids: [String]) async throws {
        _ = try await call {
            try await client.appScreenshotSetsAppScreenshotsReplaceToManyRelationship(.init(
                path: .init(id: setID),
                body: .json(.init(data: ids.map { .init(id: $0, _type: .appScreenshots) }))
            )).noContent
        }
    }

    // MARK: - Videos

    public func assetLibraryID(appID: String) async throws -> String {
        try present(try await call {
            try await client.appsAssetLibraryGetToOneRelated(.init(path: .init(id: appID))).ok.body.json.data?.id
        }, "the app's asset library")
    }

    /// Library videos with this reference name.
    public func libraryVideos(libraryID: String, referenceName: String) async throws -> [LibraryVideo] {
        let videos = try await all { cursor in
            let page = try await client.appAssetLibrariesVideosGetToManyRelated(.init(
                path: .init(id: libraryID),
                query: .init(filter_lbrack_referenceName_rbrack_: [referenceName], limit: 200, cursor: cursor)
            )).ok.body.json
            return (page.data, page.links.next)
        }
        return videos.map(Self.libraryVideo)
    }

    public func libraryVideo(id: String) async throws -> LibraryVideo {
        try await call {
            Self.libraryVideo(try await client.appAssetLibraryVideosGetInstance(.init(path: .init(id: id))).ok.body.json.data)
        }
    }

    /// Uploads a creative video into the asset library. App Store Connect
    /// processes it afterwards; poll `libraryVideo(id:)` for its state.
    public func uploadVideo(libraryID: String, fileName: String, data: Data, referenceName: String,
                            previewFrameTimeCode: String) async throws -> LibraryVideo {
        let reservation = try await call {
            try await client.appAssetLibraryVideosCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(
                    category: "CREATIVE_ASSETS",
                    fileName: fileName,
                    fileSize: Int64(data.count),
                    previewFrameTimeCode: previewFrameTimeCode,
                    referenceName: referenceName
                ),
                relationships: .init(assetLibrary: .init(data: .init(id: libraryID, _type: .appAssetLibraries))),
                _type: .appAssetLibraryVideos
            ))))).created.body.json.data
        }
        try await transfer(data, operations: Self.uploadOperations(reservation))
        return try await call {
            Self.libraryVideo(try await client.appAssetLibraryVideosUpdateInstance(.init(
                path: .init(id: reservation.id),
                body: .json(.init(data: .init(attributes: .init(uploaded: true), id: reservation.id, _type: .appAssetLibraryVideos)))
            )).ok.body.json.data)
        }
    }

    /// The localization's placements of one type, only those of one video
    /// when `videoID` is given.
    ///
    /// The type is read back from each placement rather than trusted to the
    /// server filter, so an unapplied filter can never make a caller delete
    /// the other slot.
    public func placements(localizationID: String, type: String, videoID: String? = nil) async throws -> [Placement] {
        typealias PlacementType = Operations.AppStoreVersionLocalizationsPlacementsGetToManyRelated.Input.Query
            .FilterLbrackPlacementTypeRbrackPayloadPayload
        let placements = try await all { cursor in
            let page = try await client.appStoreVersionLocalizationsPlacementsGetToManyRelated(.init(
                path: .init(id: localizationID),
                query: .init(
                    filter_lbrack_placementType_rbrack_: PlacementType(rawValue: type).map { [$0] },
                    filter_lbrack_video_rbrack_: videoID.map { [$0] },
                    limit: 200, cursor: cursor
                )
            )).ok.body.json
            return (page.data, page.links.next)
        }
        return placements.compactMap { placement -> Placement? in
            guard let placementType = placement.attributes?.placementType, placementType == type else { return nil }
            return Placement(id: placement.id, placementType: placementType)
        }
    }

    public func deletePlacement(id: String) async throws {
        _ = try await call { try await client.appAssetLibraryPlacementsDeleteInstance(.init(path: .init(id: id))).noContent }
    }

    public func placeVideo(localizationID: String, type: String, videoID: String) async throws {
        _ = try await call {
            try await client.appAssetLibraryPlacementsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(placementType: type),
                relationships: .init(
                    appStoreVersionLocalization: .init(data: .init(id: localizationID, _type: .appStoreVersionLocalizations)),
                    video: .init(data: .init(id: videoID, _type: .appAssetLibraryVideos))
                ),
                _type: .appAssetLibraryPlacements
            ))))).created
        }
    }

    // MARK: - Uploading

    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).hex
    }

    /// Sends `data` in the parts a reservation's upload operations ask for.
    func transfer(_ data: Data, operations: [Components.Schemas.UploadOperation]) async throws {
        for operation in operations {
            guard let url = operation.url.flatMap(URL.init(string:)),
                  let method = operation.method.flatMap({ HTTPRequest.Method(rawValue: $0) }),
                  let offset = operation.offset, let length = operation.length,
                  let scheme = url.scheme, let host = url.host()
            else { throw UploadError.malformedOperation }
            var request = HTTPRequest(method: method, scheme: scheme, authority: host, path: url.path(percentEncoded: true)
                + (url.query(percentEncoded: true).map { "?\($0)" } ?? ""))
            for header in operation.requestHeaders ?? [] {
                if let name = header.name.flatMap({ HTTPField.Name($0) }), let value = header.value {
                    request.headerFields[name] = value
                }
            }
            let chunk = data.subdata(in: offset..<min(offset + length, data.count))
            // Apple's object storage answers 411 to a part sent without one.
            request.headerFields[.contentLength] = String(chunk.count)
            let base = URL(string: "\(scheme)://\(host)")!
            let response: HTTPResponse
            do {
                (response, _) = try await retry.send(request, body: HTTPBody(chunk)) { [transport] request, body in
                    try await transport.send(request, body: body, baseURL: base, operationID: "upload")
                }
            } catch let error as URLError {
                throw TransportFailure(method: method.rawValue, path: url.absoluteString, reason: error.localizedDescription)
            }
            guard (200..<300).contains(response.status.code) else {
                throw UploadError.rejected(status: response.status.code, url: url)
            }
        }
    }

    static func libraryVideo(_ video: Components.Schemas.AppAssetLibraryVideo) -> LibraryVideo {
        let common = video.attributes.map(commonAttributes)
        return LibraryVideo(
            id: video.id,
            referenceName: common?.referenceName,
            state: common?.state ?? "",
            stateDetails: (common?.stateDetails ?? []).compactMap(\.code)
        )
    }

    static func uploadOperations(_ video: Components.Schemas.AppAssetLibraryVideo) -> [Components.Schemas.UploadOperation] {
        switch video.attributes {
        case .awaitingUpload(let attributes): attributes.value2.uploadOperations ?? []
        default: []
        }
    }

    static func commonAttributes(_ attributes: Components.Schemas.AppAssetLibraryVideo.AttributesPayload) -> Components.Schemas.AppAssetLibraryVideoCommonAttributes {
        switch attributes {
        case .accepted(let value): value.value1
        case .approved(let value): value.value1
        case .archived(let value): value.value1
        case .awaitingUpload(let value): value.value1
        case .complete(let value): value
        case .failed(let value): value.value1
        case .inReview(let value): value.value1
        case .prepareForSubmission(let value): value
        case .readyForReview(let value): value.value1
        case .rejected(let value): value.value1
        case .uploadComplete(let value): value.value1
        case .waitingForReview(let value): value.value1
        }
    }
}

public enum UploadError: Error, CustomStringConvertible {
    case malformedOperation
    case rejected(status: Int, url: URL)

    public var description: String {
        switch self {
        case .malformedOperation: "App Store Connect returned an upload operation without a URL, method, offset or length."
        case .rejected(let status, let url): "Uploading a part to \(url.host() ?? "") failed with \(status)."
        }
    }
}
