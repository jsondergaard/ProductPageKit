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

/// What a screenshot set App Store Connect holds has in it.
struct StoredSet: Sendable {
    let id: String
    let screenshots: [Screenshot]
}

extension AppStoreConnect {
    /// The owner's screenshot sets with their screenshots, by display type.
    func storedSets(_ owner: ScreenshotSetOwner) async throws -> [String: StoredSet] {
        var sets: [String: StoredSet] = [:]
        for (type, id) in try await screenshotSets(owner) {
            sets[type] = StoredSet(id: id, screenshots: try await screenshots(setID: id))
        }
        return sets
    }
}

/// The files one platform's screenshot set should hold, in order.
struct LocalSet: Sendable {
    let platform: Platform.Kind
    let files: [LocalScreenshot]
}

extension [FramedScreenshot] {
    /// The files of `list` on `platform` in `locale`, in list order.
    func files(of list: ShotList, on platform: Platform.Kind, in locale: StoreLocale) throws -> [LocalScreenshot] {
        try filter { $0.list == list && $0.platform.kind == platform && $0.locale == locale }.map(LocalScreenshot.init)
    }

    /// The files of `list` in `locale` on each of `platforms` that has any.
    func sets(of list: ShotList, on platforms: [Platform.Kind], in locale: StoreLocale) throws -> [LocalSet] {
        try platforms.compactMap { platform in
            let files = try files(of: list, on: platform, in: locale)
            return files.isEmpty ? nil : LocalSet(platform: platform, files: files)
        }
    }
}

/// What a localization's screenshot sets hold when a plan is made.
enum StoredSets: Sendable {
    /// What App Store Connect holds, by display type; nothing for a
    /// localization the plan creates empty.
    case stored([String: StoredSet])
    /// What a new version will copy, whose sets get ids of their own.
    case copied([String: StoredSet])
    /// A localization the plan creates, which App Store Connect fills with
    /// `source`'s screenshots, so what it holds is known only once it exists.
    case filled(by: String)
}

/// What a set's sync was planned from.
enum SetBasis: Sendable {
    /// The set as the plan read it, which it must still hold when the
    /// change runs.
    case read(SetSync)
    /// `files`, into a set App Store Connect fills with `source`'s
    /// screenshots after the plan is made.
    case filled(by: String, files: [LocalScreenshot])

    var files: [LocalScreenshot] {
        switch self {
        case .read(let sync): sync.local
        case .filled(_, let files): files
        }
    }

    var lines: [String] {
        switch self {
        case .read(let sync): sync.lines
        case .filled(let source, let files):
            ["App Store Connect starts it with \(source)'s screenshots", "replace them with \(files.map(\.name).joined(separator: ", "))"]
        }
    }
}

extension Plan {
    /// Uploads that make a localization's set on each of `sets`' platforms
    /// hold its files, against what it holds now.
    mutating func syncSets(_ subject: String, _ sets: [LocalSet], stored: StoredSets = .stored([:]),
                           owner: @escaping @Sendable (String) -> ScreenshotSetOwner, localization: Ref) {
        for set in sets {
            let basis: SetBasis
            var existingSet: String?
            switch stored {
            case .stored(let held), .copied(let held):
                let storedSet = held[set.platform.displayType]
                let sync = SetSync(local: set.files, remote: storedSet?.screenshots ?? [])
                guard !sync.isEmpty else { continue }
                basis = .read(sync)
                if case .stored = stored { existingSet = storedSet?.id }
            case .filled(let source):
                basis = .filled(by: source, files: set.files)
            }
            add(.syncSet("\(subject) · \(set.platform.name)", platform: set.platform, owner: owner, localization: localization,
                         basis: basis, existingSet: existingSet))
        }
    }
}

extension Change {
    /// An upload that makes the screenshot set of `platform` on a localization
    /// hold exactly `basis.files`. The set is read again when the change
    /// runs, since a copy made by a new version, by App Store Connect filling
    /// a new localization, or by an earlier run, is after the plan. A set the
    /// plan read that no longer holds what the plan was made from is left
    /// as it is.
    static func syncSet(_ subject: String, platform: Platform.Kind, owner: @escaping @Sendable (String) -> ScreenshotSetOwner,
                        localization: Ref, basis: SetBasis, existingSet: String?) -> Change {
        Change(action: .upload, subject: subject, lines: basis.lines, concurrent: true) { run in
            let owner = owner(try await run.id(localization))
            let setID: String
            if let existingSet {
                setID = existingSet
            } else if let found = try await run.asc.screenshotSets(owner)[platform.displayType] {
                setID = found
            } else {
                setID = try await run.asc.createScreenshotSet(owner, displayType: platform.displayType)
            }
            let sync = SetSync(local: basis.files, remote: try await run.asc.screenshots(setID: setID))
            if case .read(let planned) = basis, sync.lines != planned.lines {
                throw SetChangedSincePlan(subject: subject, planned: planned.lines, now: sync.lines)
            }
            try await sync.apply(run.asc, setID: setID)
        }
    }
}

struct SetChangedSincePlan: Error, CustomStringConvertible {
    let subject: String
    let planned: [String]
    let now: [String]

    var description: String {
        "\(subject) no longer holds what the plan was made from: it planned to \(planned.joined(separator: "; ")), and now would \(now.joined(separator: "; ")). Nothing was written to it; run the push again."
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
        // Each set to sync, in plan order, after the change that creates its
        // localization where one does.
        var sets: [(platform: Platform, locale: StoreLocale, localization: Ref, files: [LocalScreenshot], plan: Plan)] = []
        for platform in platforms {
            guard let version = versions[platform.storePlatform] else {
                plan.warn("\(platform.storePlatform.name) has no editable version, so \(platform.name) screenshots are left as they are")
                continue
            }
            if localizations[version.id] == nil {
                localizations[version.id] = try await asc.versionLocalizations(versionID: version.id)
            }
            for locale in locales {
                let files = try screenshots.files(of: .store, on: platform.kind, in: locale)
                guard !files.isEmpty else {
                    plan.warn("\(platform.name) lists no shots, so its \(locale.code) set is left as it is")
                    continue
                }
                let localizationKey = "\(version.platform.name) \(version.versionString) · \(locale.store)"
                var creation = Plan()
                let localization: Ref
                if let existing = localizations[version.id]?[locale.store] {
                    localization = .existing(existing.id)
                } else if sets.contains(where: { set in set.plan.changes.contains { $0.creates == localizationKey } }) {
                    localization = .planned(localizationKey)
                } else {
                    // App Store Connect shows a bare locale empty and refuses
                    // to submit it, so a new one gets its copy.
                    let text = copy.versionText(locale, version: version.versionString, creating: true)
                    localization = .planned(localizationKey)
                    creation.add(Change(action: .create, subject: localizationKey, fields: text.fieldChanges(from: nil),
                                        creates: localizationKey) { run in
                        let id = try await run.asc.createVersionLocalization(versionID: version.id, locale: locale.store, text: text)
                        await run.record(localizationKey, id: id)
                    })
                }
                sets.append((platform, locale, localization, files, creation))
            }
        }
        // What each existing localization holds, read once for all its
        // platforms, several localizations at a time.
        let existing = Array(Set(sets.compactMap { set -> String? in
            if case .existing(let id) = set.localization { id } else { nil }
        }))
        let asc = asc
        let held = try await existing.concurrentMap(width: Session.concurrentChanges) { id in
            (id, try await asc.storedSets(.version(id)))
        }
        let stored = Dictionary(uniqueKeysWithValues: held)
        for set in sets {
            plan = plan + set.plan
            let storedSet: StoredSet? = if case .existing(let id) = set.localization { stored[id]?[set.platform.displayType] } else { nil }
            let sync = SetSync(local: set.files, remote: storedSet?.screenshots ?? [])
            guard !sync.isEmpty else { continue }
            plan.add(.syncSet("\(set.platform.name) · \(set.locale.store)", platform: set.platform.kind,
                              owner: ScreenshotSetOwner.version, localization: set.localization,
                              basis: .read(sync), existingSet: storedSet?.id))
        }
        return plan
    }
}
