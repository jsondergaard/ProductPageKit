import ArgumentParser
import CryptoKit
import Foundation
import ProductPageKitASC
import ProductPageKitCore
import ProductPageKitPlay

/// A Google Play plan and its changes, each made in the push's edit.
typealias PlayPlan = WritePlan<PlayEdit>
typealias PlayChange = WriteChange<PlayEdit>

/// Plans `play metadata push`: each locale's listing made to hold the
/// catalog's `play.` copy.
struct PlayListingPlanner {
    let copy: StoreCopy
    let locales: [StoreLocale]
    let edit: PlayEdit

    var project: Project { copy.project }

    /// The catalog's text for a language, each field nil where the catalog
    /// has no value to upload.
    func wanted(_ locale: StoreLocale) -> PlayListing.Text {
        PlayListing.Text(title: copy.value(.playTitle, locale: locale),
                         shortDescription: copy.value(.playShortDescription, locale: locale),
                         fullDescription: copy.value(.playFullDescription, locale: locale))
    }

    func plan() async throws -> PlayPlan {
        var plan = PlayPlan()
        let remote = Dictionary(try await edit.listings().map { ($0.language, $0) }) { first, _ in first }
        if let primary = project.primaryLocale.playLanguage, let fallback = try await edit.defaultLanguage(), fallback != primary {
            plan.warn("the listing's default language is \(fallback), and the primary locale is Google Play's \(primary); change it in the Play Console")
        }
        let configured = Set(project.locales.compactMap(\.playLanguage))
        let unknown = remote.keys.filter { !configured.contains($0) }.sorted()
        if !unknown.isEmpty {
            plan.warn("Google Play lists \(unknown.joined(separator: ", ")), which no configured locale is; left as \(unknown.count == 1 ? "it is" : "they are")")
        }
        for locale in locales {
            guard let language = locale.playLanguage else { continue }
            let wanted = wanted(locale)
            let subject = "Google Play · \(language)"
            guard let existing = remote[language] else {
                let missing = Self.fields(of: wanted).filter { $0.value == nil }.map(\.field.title)
                guard missing.isEmpty, let title = wanted.title else {
                    plan.warn("\(subject) has no listing, and the catalog has no \(missing.joined(separator: ", ")) to upload in \(locale.code), so it is not created")
                    continue
                }
                let listing = PlayListing(language: language, title: title, shortDescription: wanted.shortDescription,
                                          fullDescription: wanted.fullDescription)
                plan.add(PlayChange(action: .create, subject: subject, fields: Self.changes(wanted, from: nil)) { edit in
                    try await edit.putListing(listing)
                })
                continue
            }
            let current = PlayListing.Text(title: existing.title, shortDescription: existing.shortDescription,
                                           fullDescription: existing.fullDescription)
            let patch = Self.patch(wanted, over: current)
            guard patch != PlayListing.Text() else { continue }
            plan.add(PlayChange(action: .update, subject: subject, fields: Self.changes(patch, from: current)) { edit in
                try await edit.patchListing(language: language, patch)
            })
        }
        return plan
    }

    /// Each listing field with its catalog field.
    static func fields(of text: PlayListing.Text) -> [(field: Field, value: String?)] {
        [(.playTitle, text.title), (.playShortDescription, text.shortDescription), (.playFullDescription, text.fullDescription)]
    }

    /// The fields of `wanted` that differ from `current`, the rest nil.
    static func patch(_ wanted: PlayListing.Text, over current: PlayListing.Text) -> PlayListing.Text {
        func changed(_ new: String?, _ old: String?) -> String? { new == old ? nil : new }
        return PlayListing.Text(title: changed(wanted.title, current.title),
                                shortDescription: changed(wanted.shortDescription, current.shortDescription),
                                fullDescription: changed(wanted.fullDescription, current.fullDescription))
    }

    /// How the plan shows a write of `text` over `current`.
    static func changes(_ text: PlayListing.Text, from current: PlayListing.Text?) -> [FieldChange] {
        let old = current.map(fields(of:))
        return fields(of: text).enumerated().compactMap { index, item in
            item.value.map { FieldChange(name: item.field.title, old: old?[index].value, new: $0) }
        }
    }
}

/// A framed image to upload to Google Play, read once.
struct PlayFile: Sendable {
    let name: String
    let data: Data
    let sha256: String
    let contentType: String

    init(_ screenshot: FramedScreenshot) throws {
        name = screenshot.name
        data = try Data(contentsOf: screenshot.url)
        sha256 = SHA256.hash(data: data).hex
        contentType = screenshot.url.pathExtension == "png" ? "image/png" : "image/jpeg"
    }
}

/// What an image slot needs to hold exactly the local files, in order.
/// Google Play shows a slot in upload order and cannot reorder it, so the
/// images that already match the files from the start are kept, and every
/// image after the first difference is deleted and uploaded again.
struct PlaySlotSync: Sendable {
    let local: [PlayFile]
    let kept: Int
    let delete: [PlayImage]

    var upload: ArraySlice<PlayFile> { local[kept...] }
    var isEmpty: Bool { delete.isEmpty && upload.isEmpty }

    init(local: [PlayFile], remote: [PlayImage]) {
        self.local = local
        kept = zip(local, remote).prefix { $0.sha256 == $1.sha256 }.count
        delete = Array(remote[kept...])
    }

    var lines: [String] {
        var lines: [String] = []
        if !delete.isEmpty { lines.append("delete \(delete.count)" + (kept == 0 ? "" : " after the first \(kept)")) }
        if !upload.isEmpty { lines.append("upload \(upload.map(\.name).joined(separator: ", "))") }
        lines.append("keep \(kept)")
        return lines
    }

    func apply(_ edit: PlayEdit, language: String, type: PlayImageType) async throws {
        for image in delete { try await edit.deleteImage(image, language: language, type: type) }
        for file in upload { try await edit.upload(file.data, contentType: file.contentType, language: language, type: type) }
    }
}

/// Plans `play screenshots push`: each Google Play platform's slot made to
/// hold exactly its framed images, in each locale.
struct PlayImagesPlanner {
    let screenshots: [FramedScreenshot]
    let platforms: [Platform]
    let locales: [StoreLocale]
    let edit: PlayEdit

    /// Why Google Play would refuse each framed image, so a push stops
    /// before it reads anything.
    static func problems(_ screenshots: [FramedScreenshot]) throws -> [String] {
        try screenshots.compactMap { screenshot -> [String]? in
            guard let type = screenshot.platform.kind.playImageType else { return nil }
            let data = try Data(contentsOf: screenshot.url)
            let label = "\(screenshot.platform.name) \(screenshot.name) in \(screenshot.locale.code)"
            guard let facts = ImageFacts(data) else { return ["\(label) is not an image"] }
            return type.problems(facts).map { "\(label) \($0)" }
        }.flatMap { $0 }
    }

    func plan() async throws -> PlayPlan {
        var plan = PlayPlan()
        let slots = platforms.compactMap { platform in platform.kind.playImageType.map { (platform, $0) } }.flatMap { platform, type in
            locales.compactMap { locale in locale.playLanguage.map { (platform: platform, type: type, locale: locale, language: $0) } }
        }
        let edit = edit
        let remote = try await slots.concurrentMap(width: Session.concurrentChanges) { slot in
            try await edit.images(language: slot.language, type: slot.type)
        }
        for (slot, remote) in zip(slots, remote) {
            let files = try screenshots.filter { $0.list == .store && $0.platform.kind == slot.platform.kind && $0.locale == slot.locale }
                .map(PlayFile.init)
            guard !files.isEmpty else {
                plan.warn("\(slot.platform.name) lists no shots, so its \(slot.language) images are left as they are")
                continue
            }
            let sync = PlaySlotSync(local: files, remote: remote)
            guard !sync.isEmpty else { continue }
            let (language, type) = (slot.language, slot.type)
            plan.add(PlayChange(action: .upload, subject: "Google Play · \(slot.platform.name) · \(language)", lines: sync.lines,
                                concurrent: true) { edit in
                try await sync.apply(edit, language: language, type: type)
            })
        }
        return plan
    }
}

extension Commands {
    /// The project's listing, or a stop when it has none.
    static func play(_ session: Session) throws -> GooglePlay {
        guard let play = session.project.play else { throw Stopped(description: "The project has no Google Play listing (Project.play).") }
        return play
    }

    /// Opens an edit, plans in it, asks, applies, and commits. An edit that
    /// is not committed, because there is nothing to change, the run is dry,
    /// the plan is refused or a change failed, is deleted, so nothing it
    /// held reaches the listing.
    static func publish(_ session: Session, options: WriteOptions,
                        plan: @Sendable (PlayEdit) async throws -> PlayPlan) async throws {
        let play = try play(session)
        let edit = try await session.connectPlay().edit(packageName: play.packageName)
        do {
            let plan = try await plan(edit)
            guard try session.confirm(plan, options: options) else {
                try await edit.delete()
                return
            }
            do {
                try await session.apply(plan, to: edit)
            } catch {
                session.console.print("Nothing was committed: the edit and every change in it are discarded.")
                throw error
            }
            try await edit.commit(sendForReview: play.sendsForReview)
        } catch {
            try? await edit.delete()
            throw error
        }
        session.console.print(play.sendsForReview
            ? "Committed. Google Play reviews the changes before they go live."
            : "Committed. Send the changes for review from the Play Console's Publishing overview.")
    }

    static func pushPlayMetadata(_ session: Session, locales: String, options: WriteOptions) async throws {
        try session.checkProject()
        let copy = try session.copy()
        try copy.problems().check()
        let locales = try session.locales(locales)
        try await publish(session, options: options) { edit in
            try await PlayListingPlanner(copy: copy, locales: locales, edit: edit).plan()
        }
    }

    /// Frames, then makes each image slot hold exactly the framed images.
    static func pushPlayScreenshots(_ session: Session, platforms: String, locales: String, options: WriteOptions) async throws {
        try session.checkProject()
        _ = try play(session)
        let platforms = try session.platforms(platforms, in: .googlePlay)
        let locales = try session.locales(locales)
        let report = try await frameScreenshots(session, platforms: platforms, locales: locales, lists: { $0 == .store })
        let problems = try PlayImagesPlanner.problems(report.screenshots)
        guard problems.isEmpty else {
            throw Stopped(description: "Google Play would refuse these:\n" + problems.map { "  \($0)" }.joined(separator: "\n"))
        }
        let screenshots = report.screenshots
        try await publish(session, options: options) { edit in
            try await PlayImagesPlanner(screenshots: screenshots, platforms: platforms, locales: locales, edit: edit).plan()
        }
    }

    /// Prints the tracks' releases, which languages' listings differ from
    /// the catalog, and how many images each slot holds. Writes nothing.
    static func playStatus(_ session: Session) async throws {
        try session.checkProject()
        let play = try play(session)
        let copy = try session.copy()
        let edit = try await session.connectPlay().edit(packageName: play.packageName)
        do {
            try await printStatus(session, copy: copy, edit: edit)
        } catch {
            try? await edit.delete()
            throw error
        }
        try await edit.delete()
    }

    private static func printStatus(_ session: Session, copy: StoreCopy, edit: PlayEdit) async throws {
        let console = session.console
        let project = session.project
        console.print("\(edit.packageName), default language \(try await edit.defaultLanguage() ?? "not set")")
        console.print("Tracks:")
        for track in try await edit.tracks() {
            let releases = (track.releases ?? []).map { release in
                let codes = (release.versionCodes ?? []).joined(separator: ", ")
                let share = release.userFraction.map { " to \(Int(($0 * 100).rounded()))%" } ?? ""
                return "\(release.name ?? "unnamed") (\(codes)) \(release.status ?? "")\(share)"
            }
            console.print("  \(track.track.padding(toLength: 12, withPad: " ", startingAt: 0))\(releases.isEmpty ? "no releases" : releases.joined(separator: "; "))")
        }
        let planner = PlayListingPlanner(copy: copy, locales: project.locales, edit: edit)
        let remote = Dictionary(try await edit.listings().map { ($0.language, $0) }) { first, _ in first }
        var differing: [String] = []
        var missing: [String] = []
        for locale in project.locales {
            guard let language = locale.playLanguage else { continue }
            guard let listing = remote[language] else {
                missing.append(language)
                continue
            }
            let current = PlayListing.Text(title: listing.title, shortDescription: listing.shortDescription,
                                           fullDescription: listing.fullDescription)
            let patch = PlayListingPlanner.patch(planner.wanted(locale), over: current)
            let fields = PlayListingPlanner.fields(of: patch).filter { $0.value != nil }.map(\.field.title)
            if !fields.isEmpty { differing.append("\(language) (\(fields.joined(separator: ", ")))") }
        }
        console.print("Listings: \(counted(remote.count, "language"))")
        console.print("  " + (differing.isEmpty ? "every one matches the catalog" : "differ from the catalog: \(differing.joined(separator: ", "))"))
        if !missing.isEmpty { console.print("  missing: \(missing.joined(separator: ", "))") }
        let slots = project.platforms(in: .googlePlay).compactMap { platform in platform.kind.playImageType.map { (platform, $0) } }
        guard !slots.isEmpty else { return }
        console.print("Images:")
        let languages = project.locales.compactMap(\.playLanguage)
        for (platform, type) in slots {
            let counts = try await languages.concurrentMap(width: Session.concurrentChanges) { language in
                try await edit.images(language: language, type: type).count
            }
            let groups = Dictionary(grouping: zip(languages, counts), by: \.1).sorted { $0.key > $1.key }.map { count, held in
                "\(count == 0 ? "none" : "\(count)") in \(held.count == languages.count ? "every language" : held.map(\.0).joined(separator: ", "))"
            }
            console.print("  \(platform.name): \(groups.joined(separator: "; "))")
        }
    }
}

// MARK: - Command line

struct PlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "play", abstract: "The Google Play listing.",
                                                    subcommands: [Metadata.self, Screenshots.self, Status.self])

    struct Metadata: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "metadata", abstract: "The listing's text, from the String Catalog.",
                                                        subcommands: [Push.self])

        struct Push: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Make each language's title, short and full description match the catalog's play. copy, in one edit."
            )
            @OptionGroup var locales: LocaleFlag
            @OptionGroup var options: WriteOptions

            func run() async throws {
                try await Commands.pushPlayMetadata(try Session.get(), locales: locales.locales, options: options)
            }
        }
    }

    struct Screenshots: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "screenshots", abstract: "The listing's screenshots and graphics.",
                                                        subcommands: [Push.self])

        struct Push: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Frame, then make each image slot hold exactly the framed images, uploading from the first that changed, in one edit."
            )
            @OptionGroup var platforms: PlatformFlag
            @OptionGroup var locales: LocaleFlag
            @OptionGroup var options: WriteOptions

            func run() async throws {
                try await Commands.pushPlayScreenshots(try Session.get(), platforms: platforms.platforms, locales: locales.locales,
                                                       options: options)
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the tracks' releases, which listings differ from the catalog, and the images each slot holds. Writes nothing."
        )

        func run() async throws { try await Commands.playStatus(try Session.get()) }
    }
}
