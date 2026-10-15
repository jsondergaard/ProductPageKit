import CryptoKit
import Foundation
import ProductPageKitASC
import ProductPageKitCore

/// Plans `videos push`: the product page header and search result videos.
///
/// A video goes into the app's asset library named after its kind, locale and
/// a hash of its bytes and poster frame, so a later run finds it and only a
/// changed video is uploaded again. It is then placed in its slot on the
/// editable iOS version, replacing what held the slot.
struct VideosPlanner {
    let project: Project
    let videos: [RenderedVideo]
    let motion: Motion
    let asc: AppStoreConnect
    var pollInterval: Duration = .seconds(10)
    var processingTimeout: Duration = .seconds(1800)

    static let unusable: Set<String> = ["FAILED", "REJECTED", "ARCHIVED"]
    static let processing: Set<String> = ["AWAITING_UPLOAD", "UPLOAD_COMPLETE"]

    /// `seconds` as `HH:MM:SS:FF` at `fps`.
    static func timeCode(seconds: Double, fps: Int) -> String {
        let frames = Int((seconds * Double(fps)).rounded())
        let whole = frames / fps
        return String(format: "%02d:%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60, frames % fps)
    }

    func plan() async throws -> Plan {
        var plan = Plan()
        let app = try await asc.app(bundleID: project.bundleID)
        guard let version = try await asc.editableVersions(appID: app.id)[.iOS] else {
            plan.warn("iOS has no editable version, so the videos are left as they are")
            return plan
        }
        let localizations = try await asc.versionLocalizations(versionID: version.id)
        let libraryID = try await asc.assetLibraryID(appID: app.id)
        for video in videos {
            guard let localization = localizations[video.locale.store] else {
                plan.warn("iOS \(version.versionString) has no \(video.locale.store) localization, so its \(video.asset.kind.title) video is left out")
                continue
            }
            if let change = try await planVideo(video, localizationID: localization.id, libraryID: libraryID) {
                plan.add(change)
            }
        }
        return plan
    }

    func planVideo(_ video: RenderedVideo, localizationID: String, libraryID: String) async throws -> Change? {
        let data = try Data(contentsOf: video.url)
        let kind = video.asset.kind
        let locale = video.locale
        let fileName = "\(kind.rawValue).mp4"
        let poster = Self.timeCode(seconds: video.asset.poster, fps: motion.fps)
        let digest = SHA256.hash(data: data + Data(poster.utf8)).hex
        let name = "\(project.name.lowercased())-\(kind.rawValue)-\(locale.code)-\(digest.prefix(12))"
        let type = kind.placementType
        let existing = try await asc.libraryVideos(libraryID: libraryID, referenceName: name)
            .first { $0.referenceName == name && !Self.unusable.contains($0.state) }
        let placements = try await asc.placements(localizationID: localizationID, type: type)
        if let existing, placements.count == 1,
           try await !asc.placements(localizationID: localizationID, type: type, videoID: existing.id).isEmpty {
            return nil
        }
        let subject = "iOS · \(locale.store) \(kind.title)"
        let lines = [existing == nil ? "upload \(fileName), poster at \(poster)" : "already in the asset library"]
            + (placements.isEmpty ? [] : ["replaces what the slot holds"])
        return Change(action: existing == nil ? .upload : .place, subject: subject, lines: lines) { run in
            var library = existing
            if library == nil {
                library = try await run.asc.uploadVideo(libraryID: libraryID, fileName: fileName, data: data,
                                                        referenceName: name, previewFrameTimeCode: poster)
            }
            let ready = try await waitUntilProcessed(library!, asc: run.asc)
            for placement in placements { try await run.asc.deletePlacement(id: placement.id) }
            try await run.asc.placeVideo(localizationID: localizationID, type: type, videoID: ready.id)
        }
    }

    func waitUntilProcessed(_ video: LibraryVideo, asc: AppStoreConnect) async throws -> LibraryVideo {
        let deadline = ContinuousClock.now + processingTimeout
        var video = video
        while Self.processing.contains(video.state) {
            guard ContinuousClock.now < deadline else {
                throw Stopped(description: "video \(video.id) is still processing after \(processingTimeout)")
            }
            try await Task.sleep(for: pollInterval)
            video = try await asc.libraryVideo(id: video.id)
        }
        if Self.unusable.contains(video.state) {
            let details = video.stateDetails.joined(separator: "; ")
            throw Stopped(description: "video \(video.id) is \(video.state)" + (details.isEmpty ? "" : ": \(details)"))
        }
        return video
    }
}
