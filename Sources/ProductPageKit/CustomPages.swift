import Foundation
import ProductPageKitASC
import ProductPageKitCore

/// Plans `pages push`: each custom page made to hold its promotional text,
/// keywords and framed screenshots in every locale.
///
/// A page is found by name and created when missing. Its newest version is
/// changed while it is editable. Once App Review has approved it, a new
/// version is made, which App Store Connect starts as a copy of the approved
/// one, so only what differs is written; the approved version keeps serving
/// until the new one is approved. Nothing is ever submitted for review.
struct CustomPagesPlanner {
    let copy: StoreCopy
    /// The custom pages' framed screenshots.
    let screenshots: [FramedScreenshot]
    let pages: [CustomPage]
    let platforms: [Platform.Kind]
    let locales: [StoreLocale]
    let asc: AppStoreConnect

    var project: Project { copy.project }

    /// The keywords a custom page is assigned come from the iOS version's,
    /// the only platform whose pages take screenshots.
    static let keywordPlatform = StorePlatform.iOS.rawValue

    func plan() async throws -> Plan {
        let app = try await asc.app(bundleID: project.bundleID)
        let records = try await asc.customPages(appID: app.id)
        var pools: [String: Set<String>] = [:]
        for locale in locales where pages.contains(where: { !$0.keywords.isEmpty }) {
            pools[locale.store] = try await asc.searchKeywords(appID: app.id, locale: locale.store, platform: Self.keywordPlatform)
        }
        var plan = Plan()
        for page in pages {
            plan = plan + (try await self.plan(page, record: records.first { $0.name == page.name }, appID: app.id, pools: pools))
        }
        return plan
    }

    /// What one locale of a page should hold.
    private struct Wanted {
        let locale: StoreLocale
        /// Nil leaves App Store Connect's, as for any copy not yet translated.
        let promotionalText: String?
        let keywords: [String]
        let sets: [(platform: Platform.Kind, files: [LocalScreenshot])]
    }

    /// What a version's localization holds now.
    private struct Current {
        let localization: CustomPageLocalization
        let keywords: Set<String>
        /// By display type.
        let sets: [String: StoredSet]
    }

    private func plan(_ page: CustomPage, record: CustomPageRecord?, appID: String, pools: [String: Set<String>]) async throws -> Plan {
        var plan = Plan()
        let name = "\(page.name) page"
        let wanted = try locales.map { try self.wanted(page, locale: $0) }
        for locale in wanted {
            let unavailable = locale.keywords.filter { !(pools[locale.locale.store] ?? []).contains($0) }
            if !unavailable.isEmpty {
                plan.warn("\(name) · \(locale.locale.store): \(unavailable.joined(separator: ", ")) is not among the live version's keywords yet, so it is left out until a version with it is approved")
            }
        }
        let keywordsTaken = { (locale: Wanted) in locale.keywords.filter { (pools[locale.locale.store] ?? []).contains($0) } }

        guard let record else {
            return plan + created(page, wanted: wanted, keywords: keywordsTaken, appID: appID)
        }
        if !record.isVisible {
            plan.add(Change(action: .update, subject: name, fields: [FieldChange(name: "visible", old: "false", new: "true")]) { run in
                try await run.asc.showCustomPage(id: record.id)
            })
        }
        let versions = try await asc.customPageVersions(pageID: record.id)
        guard let newest = versions.last else {
            plan.warn("\(name) has no version, so it is left as it is")
            return plan
        }
        let current = try await self.current(versionID: newest.id)
        var changes = Plan()
        let versionKey = "\(name) version"
        let replacing = !newest.isEditable
        for locale in wanted {
            let localizationKey = "\(name) · \(locale.locale.store)"
            let taken = keywordsTaken(locale)
            guard let now = current[locale.locale.store] else {
                let version: Ref = replacing ? .planned(versionKey) : .existing(newest.id)
                changes = changes + newLocalization(locale, keywords: taken, version: version, key: localizationKey, page: name)
                continue
            }
            let localization: Ref = replacing ? .planned(localizationKey) : .existing(now.localization.id)
            if let text = locale.promotionalText, text != now.localization.promotionalText {
                changes.add(Change(action: .update, subject: localizationKey,
                                   fields: [FieldChange(name: "promotionalText", old: now.localization.promotionalText, new: text)]) { run in
                    try await run.asc.updateCustomPageLocalization(id: try await run.id(localization), promotionalText: text)
                })
            }
            let assign = taken.filter { !now.keywords.contains($0) }
            let unassign = now.keywords.subtracting(taken).sorted()
            if !assign.isEmpty || !unassign.isEmpty {
                changes.add(keywordChange(localizationKey, localization: localization, assign: assign, unassign: unassign))
            }
            for (platform, files) in locale.sets {
                let set = now.sets[platform.displayType]
                let sync = SetSync(local: files, remote: set?.screenshots ?? [])
                guard !sync.isEmpty else { continue }
                changes.add(.syncSet("\(localizationKey) · \(platform.name)", platform: platform, owner: ScreenshotSetOwner.customPage,
                                     localization: localization, planned: sync, existingSet: replacing ? nil : set?.id))
            }
        }
        guard !changes.changes.isEmpty else { return plan + changes }
        if replacing {
            guard newest.state == "APPROVED" else {
                plan.warn("\(name)'s version \(newest.version ?? "") is \(newest.state ?? "in an unknown state"), so it is left as it is until App Review is done with it")
                return plan
            }
            plan.add(Change(action: .create, subject: versionKey,
                            lines: ["a copy of approved version \(newest.version ?? ""), which keeps serving until this one is approved"],
                            creates: versionKey) { run in
                let id = try await run.asc.createCustomPageVersion(pageID: record.id)
                await run.record(versionKey, id: id)
                for (locale, localization) in try await run.asc.customPageLocalizations(versionID: id) {
                    await run.record("\(name) · \(locale)", id: localization.id)
                }
            })
        }
        return plan + changes
    }

    /// A page App Store Connect does not have yet: created with its first
    /// locale, shown, then every other locale added.
    private func created(_ page: CustomPage, wanted: [Wanted], keywords: (Wanted) -> [String], appID: String) -> Plan {
        var plan = Plan()
        let name = "\(page.name) page"
        guard let first = wanted.first else { return plan }
        let firstKey = "\(name) · \(first.locale.store)"
        let versionKey = "\(name) version"
        plan.add(Change(action: .create, subject: name,
                        fields: first.promotionalText.map { [FieldChange(name: "promotionalText · \(first.locale.store)", old: nil, new: $0)] } ?? [],
                        lines: ["shown, so links to it open it"], creates: firstKey) { run in
            let id = try await run.asc.createCustomPage(appID: appID, name: page.name, locale: first.locale.store,
                                                         promotionalText: first.promotionalText)
            try await run.asc.showCustomPage(id: id)
            guard let version = try await run.asc.customPageVersions(pageID: id).last else { return }
            await run.record(versionKey, id: version.id)
            for (locale, localization) in try await run.asc.customPageLocalizations(versionID: version.id) {
                await run.record("\(name) · \(locale)", id: localization.id)
            }
        })
        plan = plan + contents(first, keywords: keywords(first), localization: .planned(firstKey), key: firstKey)
        for locale in wanted.dropFirst() {
            plan = plan + newLocalization(locale, keywords: keywords(locale), version: .planned(versionKey),
                                          key: "\(name) · \(locale.locale.store)", page: name)
        }
        return plan
    }

    /// A localization the version does not have, and what it holds.
    private func newLocalization(_ locale: Wanted, keywords: [String], version: Ref, key: String, page: String) -> Plan {
        var plan = Plan()
        plan.add(Change(action: .create, subject: key,
                        fields: locale.promotionalText.map { [FieldChange(name: "promotionalText", old: nil, new: $0)] } ?? [],
                        creates: key) { run in
            let id = try await run.asc.createCustomPageLocalization(versionID: try await run.id(version), locale: locale.locale.store,
                                                                    promotionalText: locale.promotionalText)
            await run.record(key, id: id)
        })
        return plan + contents(locale, keywords: keywords, localization: .planned(key), key: key)
    }

    /// The keywords and screenshot sets of a localization that starts empty.
    private func contents(_ locale: Wanted, keywords: [String], localization: Ref, key: String) -> Plan {
        var plan = Plan()
        if !keywords.isEmpty { plan.add(keywordChange(key, localization: localization, assign: keywords, unassign: [])) }
        for (platform, files) in locale.sets {
            plan.add(.syncSet("\(key) · \(platform.name)", platform: platform, owner: ScreenshotSetOwner.customPage,
                              localization: localization, planned: SetSync(local: files, remote: []), existingSet: nil))
        }
        return plan
    }

    private func keywordChange(_ subject: String, localization: Ref, assign: [String], unassign: [String]) -> Change {
        var lines: [String] = []
        if !assign.isEmpty { lines.append("assign keywords \(assign.joined(separator: ", "))") }
        if !unassign.isEmpty { lines.append("unassign keywords \(unassign.joined(separator: ", "))") }
        return Change(action: .update, subject: subject, lines: lines) { run in
            let id = try await run.id(localization)
            // A new version's copy is read again, and must hold what the
            // plan was made from.
            let assigned = try await run.asc.assignedKeywords(localizationID: id)
            let add = assign.filter { !assigned.contains($0) }
            let remove = unassign.filter(assigned.contains)
            if !add.isEmpty { try await run.asc.assignKeywords(add, localizationID: id) }
            if !remove.isEmpty { try await run.asc.unassignKeywords(remove, localizationID: id) }
        }
    }

    private func wanted(_ page: CustomPage, locale: StoreLocale) throws -> Wanted {
        let terms = Set((copy.keywords(locale: locale) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let sets = try screenshots.sets(of: page.list, on: page.platforms.filter(platforms.contains), in: locale)
        return Wanted(locale: locale, promotionalText: copy.value(page.promotionalText, locale: locale),
                      keywords: page.keywords.filter { terms.contains($0.lowercased()) }, sets: sets)
    }

    private func current(versionID: String) async throws -> [String: Current] {
        var current: [String: Current] = [:]
        for (locale, localization) in try await asc.customPageLocalizations(versionID: versionID) {
            current[locale] = Current(localization: localization, keywords: try await asc.assignedKeywords(localizationID: localization.id),
                                      sets: try await asc.storedSets(.customPage(localization.id)))
        }
        return current
    }
}
