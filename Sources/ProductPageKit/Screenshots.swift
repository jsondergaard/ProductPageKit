import Foundation
import ProductPageKitASC
import ProductPageKitCore

/// A screenshot to upload, read once.
struct LocalScreenshot: Sendable {
    let name: String
    let data: Data
    let checksum: String

    init(_ screenshot: FramedScreenshot) throws {
        name = screenshot.name
        data = try Data(contentsOf: screenshot.url)
        checksum = AppStoreConnect.md5(data)
    }
}

/// What a screenshot set needs to hold exactly the local files, in order.
///
/// Files are matched to what App Store Connect has by MD5, so an unchanged
/// file is never sent again. A remote screenshot matches at most one file,
/// and one App Store Connect failed to process matches none.
struct SetSync: Sendable {
    let local: [LocalScreenshot]
    /// The remote screenshot kept for each local file, by index.
    let kept: [Int: Screenshot]
    let delete: [Screenshot]
    let reorder: Bool

    var upload: [LocalScreenshot] { local.indices.filter { kept[$0] == nil }.map { local[$0] } }
    var isEmpty: Bool { delete.isEmpty && upload.isEmpty && !reorder }

    init(local: [LocalScreenshot], remote: [Screenshot]) {
        self.local = local
        var available = remote.filter { $0.state != "FAILED" }
        var kept: [Int: Screenshot] = [:]
        for (index, file) in local.enumerated() {
            if let match = available.firstIndex(where: { $0.checksum == file.checksum }) {
                kept[index] = available.remove(at: match)
            }
        }
        let keptIDs = Set(kept.values.map(\.id))
        self.kept = kept
        delete = remote.filter { !keptIDs.contains($0.id) }
        reorder = kept.count < local.count
            || kept.keys.sorted().map { kept[$0]!.id } != remote.map(\.id).filter(keptIDs.contains)
    }

    var lines: [String] {
        var lines: [String] = []
        if !upload.isEmpty { lines.append("upload \(upload.map(\.name).joined(separator: ", "))") }
        if !delete.isEmpty { lines.append("delete \(delete.count) no longer in the set") }
        lines.append("keep \(kept.count)" + (reorder ? ", then order by file name" : ""))
        return lines
    }

    /// Deletes first, since a set holds at most ten, then uploads, then puts
    /// the set in file order.
    func apply(_ asc: AppStoreConnect, setID: String) async throws {
        for screenshot in delete { try await asc.deleteScreenshot(id: screenshot.id) }
        var order: [String] = []
        for (index, file) in local.enumerated() {
            if let kept = kept[index] {
                order.append(kept.id)
            } else {
                order.append(try await asc.uploadScreenshot(setID: setID, fileName: file.name, data: file.data))
            }
        }
        if reorder { try await asc.orderScreenshots(setID: setID, ids: order) }
    }
}

/// Plans `screenshots push`: each set on the editable versions made to hold
/// exactly the framed screenshots, in the platform's order.
struct ScreenshotsPlanner {
    let copy: StoreCopy
    let screenshots: [FramedScreenshot]
    let platforms: [Platform]
    let locales: [StoreLocale]
    let asc: AppStoreConnect

    var project: Project { copy.project }

    func plan() async throws -> Plan {
        var plan = Plan()
        let app = try await asc.app(bundleID: project.bundleID)
        let versions = try await asc.editableVersions(appID: app.id)
        var localizations: [String: [String: Localized<VersionText>]] = [:]
        for platform in platforms {
            guard let version = versions[platform.storePlatform] else {
                plan.warn("\(platform.storePlatform.name) has no editable version, so \(platform.name) screenshots are left as they are")
                continue
            }
            if localizations[version.id] == nil {
                localizations[version.id] = try await asc.versionLocalizations(versionID: version.id)
            }
            for locale in locales {
                let files = try screenshots.filter { $0.platform.kind == platform.kind && $0.locale == locale }.map(LocalScreenshot.init)
                guard !files.isEmpty else {
                    plan.warn("\(platform.name) lists no shots, so its \(locale.code) set is left as it is")
                    continue
                }
                let localizationKey = "\(version.platform.name) \(version.versionString) · \(locale.store)"
                let localization: Ref
                if let existing = localizations[version.id]?[locale.store] {
                    localization = .existing(existing.id)
                } else if plan.changes.contains(where: { $0.creates == localizationKey }) {
                    localization = .planned(localizationKey)
                } else {
                    // App Store Connect shows a bare locale empty and refuses
                    // to submit it, so a new one gets its copy.
                    let text = copy.versionText(locale, version: version.versionString, creating: true)
                    localization = .planned(localizationKey)
                    plan.add(Change(action: .create, subject: localizationKey, fields: text.fieldChanges(from: nil),
                                    creates: localizationKey) { run in
                        let id = try await run.asc.createVersionLocalization(versionID: version.id, locale: locale.store, text: text)
                        await run.record(localizationKey, id: id)
                    })
                }
                plan = plan + (try await planSet(platform, locale: locale, localization: localization, files: files))
            }
        }
        return plan
    }

    func planSet(_ platform: Platform, locale: StoreLocale, localization: Ref, files: [LocalScreenshot]) async throws -> Plan {
        var plan = Plan()
        let subject = "\(platform.name) · \(locale.store)"
        var existingSet: String?
        if case .existing(let id) = localization {
            existingSet = try await asc.screenshotSets(.version(id))[platform.displayType]
        }
        let setID = existingSet
        let remote = try await setID.asyncMap { try await asc.screenshots(setID: $0) } ?? []
        let sync = SetSync(local: files, remote: remote)
        guard !sync.isEmpty else { return plan }
        plan.add(Change(action: .upload, subject: subject, lines: sync.lines) { run in
            let id: String
            if let setID {
                id = setID
            } else {
                id = try await run.asc.createScreenshotSet(.version(try await run.id(localization)), displayType: platform.displayType)
            }
            try await sync.apply(run.asc, setID: id)
        })
        return plan
    }
}
