import Foundation
import ProductPageKitASC
import ProductPageKitCore

extension StoreCopy {
    /// What a version localization should hold. A new localization also gets
    /// the fallback keywords when the locale has none, so it never goes live
    /// without any.
    func versionText(_ locale: StoreLocale, version: String, creating: Bool) -> VersionText {
        var text = VersionText()
        text.description = value(.description, locale: locale)
        text.keywords = creating ? keywords(locale: locale) : value(.keywords, locale: locale)
        text.promotionalText = value(.promotionalText, locale: locale)
        text.whatsNew = value(.whatsNew(version), locale: locale)
        text.marketingURL = project.metadata.urls.marketing
        text.supportURL = project.metadata.urls.support
        return text
    }

    func appInfoText(_ locale: StoreLocale) -> AppInfoText {
        var text = AppInfoText()
        text.name = value(.name, locale: locale)
        text.subtitle = value(.subtitle, locale: locale)
        text.privacyPolicyURL = project.metadata.urls.privacy
        return text
    }
}

/// Plans `metadata push`: App Store Connect's text made to match the catalog
/// and the configuration.
struct MetadataPlanner {
    let copy: StoreCopy
    let environment: Environment
    let asc: AppStoreConnect
    let locales: [StoreLocale]
    let platforms: [StorePlatform]

    var project: Project { copy.project }

    func plan() async throws -> Plan {
        let app = try await asc.app(bundleID: project.bundleID)
        var plan = try await planAppInfo(appID: app.id)
        let versions = try await asc.editableVersions(appID: app.id)
        for platform in platforms {
            guard let version = versions[platform] else {
                plan.warn("\(platform.name) has no editable version, so its text is left as it is")
                continue
            }
            plan = plan + (try await planVersion(version))
        }
        return plan
    }

    /// Name, subtitle and privacy policy: per locale, on the app.
    func planAppInfo(appID: String) async throws -> Plan {
        var plan = Plan()
        guard let info = try await asc.appInfo(appID: appID) else {
            plan.warn("the app has no app info, so name and subtitle are left as they are")
            return plan
        }
        let live = try await asc.appInfoLocalizations(appInfoID: info.id)
        for locale in locales {
            let wanted = copy.appInfoText(locale)
            let subject = "App · \(locale.store)"
            if let existing = live[locale.store] {
                let changes = wanted.changes(from: existing.text)
                guard !changes.isEmpty else { continue }
                plan.add(Change(action: .update, subject: subject, fields: changes.fieldChanges(from: existing.text)) { run in
                    try await run.asc.updateAppInfoLocalization(id: existing.id, changes)
                })
            } else if let name = wanted.name {
                plan.add(Change(action: .create, subject: subject, fields: wanted.fieldChanges(from: nil)) { run in
                    try await run.asc.createAppInfoLocalization(appInfoID: info.id, locale: locale.store, name: name, text: wanted)
                })
            } else {
                plan.warn("\(locale.code) has no translated name, so \(locale.store) is not added to the app")
            }
        }
        return plan
    }

    /// Copyright, App Review information, and each locale's text.
    func planVersion(_ version: AppVersion) async throws -> Plan {
        var plan = Plan()
        let label = "\(version.platform.name) \(version.versionString)"
        if version.copyright != project.metadata.copyright {
            let copyright = project.metadata.copyright
            plan.add(Change(action: .update, subject: label,
                            fields: [FieldChange(name: "copyright", old: version.copyright, new: copyright, isSecret: false)]) { run in
                try await run.asc.updateCopyright(versionID: version.id, copyright)
            })
        }
        if copy.catalog.strings[Field.whatsNew(version.versionString).key] == nil {
            plan.warn("\(label) has no What's New in \(project.metadata.catalog)")
        }

        plan = plan + (try await planReview(version, label: label))

        let live = try await asc.versionLocalizations(versionID: version.id)
        for locale in locales {
            let subject = "\(label) · \(locale.store)"
            if let existing = live[locale.store] {
                let changes = copy.versionText(locale, version: version.versionString, creating: false).changes(from: existing.text)
                guard !changes.isEmpty else { continue }
                plan.add(Change(action: .update, subject: subject, fields: changes.fieldChanges(from: existing.text)) { run in
                    try await run.asc.updateVersionLocalization(id: existing.id, changes)
                })
            } else {
                let wanted = copy.versionText(locale, version: version.versionString, creating: true)
                plan.add(Change(action: .create, subject: subject, fields: wanted.fieldChanges(from: nil)) { run in
                    try await Self.createVersionLocalization(run.asc, versionID: version.id, locale: locale.store, text: wanted)
                })
            }
        }
        return plan
    }

    /// Adding a locale to the app makes App Store Connect add it to the
    /// editable versions too, so a create planned before that collides. The
    /// localization it made is then updated instead.
    static func createVersionLocalization(_ asc: AppStoreConnect, versionID: String, locale: String, text: VersionText) async throws {
        do {
            try await asc.createVersionLocalization(versionID: versionID, locale: locale, text: text)
        } catch let error as ASCError where error.isDuplicate {
            guard let existing = try await asc.versionLocalizations(versionID: versionID)[locale] else { throw error }
            let changes = text.changes(from: existing.text)
            if !changes.isEmpty { try await asc.updateVersionLocalization(id: existing.id, changes) }
        }
    }

    /// The notes, the account App Review signs in with and who it calls. The
    /// account and the contact come from the environment.
    func planReview(_ version: AppVersion, label: String) async throws -> Plan {
        var plan = Plan()
        var wanted = ReviewInfo()
        wanted.notes = copy.value(.reviewNotes, locale: project.primaryLocale)
        if let account = project.metadata.reviewAccount {
            if let name = environment[account.nameVariable], let password = environment[account.passwordVariable] {
                wanted.demoAccountRequired = true
                wanted.demoAccountName = name
                wanted.demoAccountPassword = password
            } else {
                plan.warn("\(account.nameVariable) and \(account.passwordVariable) are not set, so App Review gets no account to sign in with")
            }
        }
        if let contact = project.metadata.reviewContact {
            wanted.contactFirstName = environment[contact.prefix + "FIRST_NAME"]
            wanted.contactLastName = environment[contact.prefix + "LAST_NAME"]
            wanted.contactPhone = environment[contact.prefix + "PHONE"]
            wanted.contactEmail = environment[contact.prefix + "EMAIL"]
        }
        guard !wanted.isEmpty else { return plan }
        let review = wanted
        let subject = "\(label) App Review"
        if let existing = try await asc.reviewDetail(versionID: version.id) {
            let changes = review.changes(from: existing.info)
            guard !changes.isEmpty else { return plan }
            plan.add(Change(action: .update, subject: subject, fields: changes.fieldChanges(from: existing.info)) { run in
                try await run.asc.updateReviewDetail(id: existing.id, changes)
            })
        } else {
            plan.add(Change(action: .create, subject: subject, fields: review.fieldChanges(from: nil)) { run in
                try await run.asc.createReviewDetail(versionID: version.id, review)
            })
        }
        return plan
    }
}

/// App Store Connect's text as a catalog: the newest version's listing on one
/// platform, What's New for every version, the review notes, the in-app
/// products' review note, and each custom page's promotional text. Every
/// value counts as translated, since it is what customers see.
struct LiveCopy {
    let project: Project
    let asc: AppStoreConnect
    let platform: StorePlatform

    func read() async throws -> StoreCopy {
        var copy = StoreCopy(project: project, catalog: StringCatalog(sourceLanguage: project.primaryLocale.code))
        let app = try await asc.app(bundleID: project.bundleID)
        let versions = try await asc.versions(appID: app.id).filter { $0.platform == platform }
        guard let newest = versions.first else {
            throw Stopped(description: "\(app.name) has no \(platform.name) version.")
        }
        func locale(_ store: String) -> StoreLocale? { project.locales.first { $0.store == store } }

        if let info = try await asc.appInfo(appID: app.id) {
            for localization in try await asc.appInfoLocalizations(appInfoID: info.id).values {
                guard let locale = locale(localization.locale) else { continue }
                if let name = localization.text.name { copy.set(name, field: .name, locale: locale) }
                if let subtitle = localization.text.subtitle { copy.set(subtitle, field: .subtitle, locale: locale) }
            }
        }
        for version in versions.reversed() {
            for localization in try await asc.versionLocalizations(versionID: version.id).values {
                guard let locale = locale(localization.locale) else { continue }
                let text = localization.text
                if let whatsNew = text.whatsNew, !whatsNew.isEmpty {
                    copy.set(whatsNew, field: .whatsNew(version.versionString), locale: locale)
                }
                guard version.id == newest.id else { continue }
                if let value = text.description { copy.set(value, field: .description, locale: locale) }
                if let value = text.keywords { copy.set(value, field: .keywords, locale: locale) }
                if let value = text.promotionalText { copy.set(value, field: .promotionalText, locale: locale) }
            }
        }
        if let notes = try await asc.reviewDetail(versionID: newest.id)?.info.notes {
            copy.set(notes, field: .reviewNotes, locale: project.primaryLocale)
        }
        if project.products != nil, let note = try await productReviewNote(appID: app.id) {
            copy.set(note, field: .productReviewNote, locale: project.primaryLocale)
        }
        if !project.customPages.isEmpty {
            let records = try await asc.customPages(appID: app.id)
            for page in project.customPages {
                guard let record = records.first(where: { $0.name == page.name }),
                      let newest = try await asc.customPageVersions(pageID: record.id).last else { continue }
                for localization in try await asc.customPageLocalizations(versionID: newest.id).values {
                    guard let locale = locale(localization.locale), let text = localization.promotionalText, !text.isEmpty else { continue }
                    copy.set(text, field: page.promotionalText, locale: locale)
                }
            }
        }
        return copy
    }

    /// A subscription's review note, or else a one-time purchase's.
    private func productReviewNote(appID: String) async throws -> String? {
        for group in try await asc.subscriptionGroups(appID: appID) {
            if let note = try await asc.subscriptions(groupID: group.id).compactMap(\.settings.reviewNote).first { return note }
        }
        return try await asc.inAppPurchases(appID: appID).compactMap(\.settings.reviewNote).first
    }
}

extension StoreCopy {
    /// Takes every value in `live`, the source language first: setting it
    /// marks changed translations for review, and the live translations that
    /// follow are reviewed already. Returns the `key · language` pairs that
    /// changed.
    mutating func merge(_ live: StoreCopy) -> [String] {
        let before = catalog
        for key in live.catalog.strings.keys.sorted() {
            guard let field = live.field(key) else { continue }
            let languages = (live.catalog.strings[key]?.localizations ?? [:]).keys
                .sorted { ($0 == live.catalog.sourceLanguage ? 0 : 1, $0) < ($1 == live.catalog.sourceLanguage ? 0 : 1, $1) }
            for language in languages {
                guard let value = live.catalog.unit(key, language: language)?.value,
                      let locale = project.locale(language) else { continue }
                set(value, field: field, locale: locale)
            }
        }
        return catalog.strings.keys.sorted().flatMap { key in
            Set((catalog.strings[key]?.localizations ?? [:]).keys).sorted().compactMap { language in
                catalog.unit(key, language: language) != before.unit(key, language: language) ? "\(key) · \(language)" : nil
            }
        }
    }
}
