public import Foundation

/// Something wrong with the configuration, the copy or the catalogue. Errors
/// stop a push; warnings are printed with its plan.
public struct Problem: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: Hashable, Sendable { case error, warning }

    public let severity: Severity
    public let message: String

    public static func error(_ message: String) -> Problem { Problem(severity: .error, message: message) }
    public static func warning(_ message: String) -> Problem { Problem(severity: .warning, message: message) }

    public var description: String { message }
}

public struct ProblemsError: Error, CustomStringConvertible {
    public let problems: [Problem]
    public var description: String { problems.map { "error: \($0)" }.joined(separator: "\n") }
}

extension [Problem] {
    public var errors: [Problem] { filter { $0.severity == .error } }
    public var warnings: [Problem] { filter { $0.severity == .warning } }

    /// Throws when any problem is an error.
    public func check() throws {
        if !errors.isEmpty { throw ProblemsError(problems: errors) }
    }
}

/// The App Store copy in the project's String Catalog.
///
/// The source language's values always count. A translation counts once its
/// state is `translated`: one that is new or needs review leaves App Store
/// Connect's value as it is.
public struct StoreCopy: Sendable {
    public let project: Project
    public internal(set) var catalog: StringCatalog

    public init(project: Project, catalog: StringCatalog) {
        self.project = project
        self.catalog = catalog
    }

    public static func url(_ project: Project, root: URL) -> URL {
        root.appending(path: project.metadata.catalog)
    }

    /// The catalog at `Metadata.catalog`, or an empty one in the primary
    /// language when there is no file yet.
    public static func load(_ project: Project, root: URL) throws -> StoreCopy {
        let url = url(project, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StoreCopy(project: project, catalog: StringCatalog(sourceLanguage: project.primaryLocale.code))
        }
        return StoreCopy(project: project, catalog: try StringCatalog.read(from: url))
    }

    /// Writes the catalog. Returns whether the file changed.
    @discardableResult
    public func write(root: URL) throws -> Bool {
        let url = Self.url(project, root: root)
        let data = try catalog.data()
        guard (try? Data(contentsOf: url)) != data else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }

    var source: String { catalog.sourceLanguage }

    // MARK: - Values

    /// The value to upload for a locale, or nil to leave App Store Connect's.
    public func value(_ field: Field, locale: StoreLocale) -> String? {
        guard let entry = catalog.strings[field.key] else { return nil }
        let language = entry.isTranslatable ? locale.code : source
        guard let unit = entry.localizations?[language]?.stringUnit, !unit.value.isEmpty,
              language == source || unit.state == StringCatalog.State.translated.rawValue
        else { return nil }
        return unit.value
    }

    /// Keywords for a locale, or the fallback when it has none: App Store
    /// Connect drops an app from search in a storefront with no keywords.
    public func keywords(locale: StoreLocale) -> String? {
        value(.keywords, locale: locale) ?? project.metadata.fallbackKeywords
    }

    /// The field a catalog key holds, or nil for a key that is not App Store copy.
    public func field(_ key: String) -> Field? {
        if let version = Field.version(ofWhatsNew: key) { return .whatsNew(version) }
        return fields.first { $0.key == key }
    }

    /// Every field the project has, in the order the review page shows them:
    /// the listing, What's New newest first, the captions, each custom
    /// page's promotional text, then the notes for App Review.
    public var fields: [Field] {
        var fields = Field.listing + releases.reversed().map(Field.whatsNew) + captionFields
            + project.customPages.map(\.promotionalText) + [.reviewNotes]
        if project.products != nil { fields.append(.productReviewNote) }
        return fields
    }

    var captionFields: [Field] {
        project.captionSubjects.flatMap { subject in Caption.Line.allCases.map { Field.caption(subject, $0) } }
    }

    /// The caption for `subject` in `locale`. A line without a translation
    /// is the source language's, and is listed in `untranslated`. Nil when
    /// the source language has no headline.
    public func caption(_ subject: CaptionSubject, locale: StoreLocale) -> (caption: Caption, untranslated: [Field])? {
        var untranslated: [Field] = []
        func line(_ line: Caption.Line) -> String? {
            let field = Field.caption(subject, line)
            if let value = value(field, locale: locale) { return value }
            guard let value = value(field, locale: StoreLocale(source, store: source)) else { return nil }
            untranslated.append(field)
            return value
        }
        guard let headline = line(.headline) else { return nil }
        return (Caption(kicker: line(.kicker), headline: headline, subline: line(.subline)), untranslated)
    }

    /// Versions with What's New in the catalog.
    public var releases: [String] {
        catalog.strings.keys.compactMap(Field.version(ofWhatsNew:))
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    // MARK: - Editing

    /// Sets a value, creating the entry with its comment when it is new.
    public mutating func set(_ value: String, field: Field, locale: StoreLocale) {
        if catalog.strings[field.key] == nil {
            catalog.strings[field.key] = StringCatalog.Entry(comment: field.comment, shouldTranslate: field.isTranslatable)
        }
        catalog.set(value, for: field.key, language: field.isTranslatable ? locale.code : source)
    }

    /// Marks a translation as reviewed, keeping its value. Returns false when
    /// there is nothing to approve.
    @discardableResult
    public mutating func approve(_ field: Field, locale: StoreLocale) -> Bool {
        guard let unit = catalog.unit(field.key, language: locale.code), !unit.value.isEmpty else { return false }
        catalog.strings[field.key]?.localizations?[locale.code]?.stringUnit?.state = StringCatalog.State.translated.rawValue
        return true
    }

    /// Adds What's New for a version with an empty value in every locale, for
    /// writing in Xcode's editor.
    public mutating func addRelease(_ version: String) throws {
        let field = Field.whatsNew(version)
        guard Field.version(ofWhatsNew: field.key) != nil else { throw InvalidVersion(version: version) }
        guard catalog.strings[field.key] == nil else { throw ReleaseExists(version: version) }
        var entry = StringCatalog.Entry(comment: field.comment)
        entry.localizations = Dictionary(uniqueKeysWithValues: project.locales.map {
            ($0.code, StringCatalog.Localization(stringUnit: StringCatalog.StringUnit(state: .new, value: "")))
        })
        catalog.strings[field.key] = entry
    }

    // MARK: - Validation

    /// Every problem in the copy, so one run reports them all.
    public func problems() -> [Problem] {
        var problems: [Problem] = []
        let file = project.metadata.catalog
        if source != project.primaryLocale.code {
            problems.append(.error("\(file) is in \(source), and the primary locale is \(project.primaryLocale.code)"))
        }
        let known = Set(fields.map(\.key))
        for key in catalog.strings.keys.sorted() where !known.contains(key) {
            problems.append(.error("\(key) is not App Store copy ProductPageKit knows"))
        }
        let codes = Set(project.locales.map(\.code))
        for field in fields {
            problems += self.problems(field, codes: codes)
        }
        problems += keywordProblems()
        return problems
    }

    func problems(_ field: Field, codes: Set<String>) -> [Problem] {
        guard let entry = catalog.strings[field.key] else {
            return field.isRequired && Field.version(ofWhatsNew: field.key) == nil ? [.error("\(field.key) is missing")] : []
        }
        var problems: [Problem] = []
        let localizations = entry.localizations ?? [:]
        if localizations[source]?.stringUnit?.value.isEmpty != false {
            // An optional caption line nobody wrote.
            guard field.isRequired else { return [] }
            problems.append(.error("\(field.key) has no \(source) value"))
        }
        if entry.isTranslatable != field.isTranslatable {
            problems.append(.error("\(field.key) must be marked \(field.isTranslatable ? "to translate" : "not to translate")"))
        }
        for (language, localization) in localizations.sorted(by: { $0.key < $1.key }) {
            guard let unit = localization.stringUnit, !unit.value.isEmpty else { continue }
            if !field.isTranslatable, language != source {
                problems.append(.error("\(field.key) is not translated in App Store Connect, so its \(language) value would never upload"))
            } else if !codes.contains(language) {
                problems.append(.warning("\(field.key) has \(language), which is not a configured locale"))
            }
            if let maxLength = field.maxLength, unit.value.count > maxLength {
                problems.append(.error("\(field.key) · \(language): \(unit.value.count) characters, App Store Connect caps \(field.title) at \(maxLength)"))
            }
            if language == source || unit.state == StringCatalog.State.translated.rawValue {
                for link in project.metadata.requiredLinks[field] ?? [] where !unit.value.contains(link) {
                    problems.append(.error("\(field.key) · \(language): must link \(link)"))
                }
            }
        }
        guard field.isTranslatable else { return problems }
        // One line per field and state: thirty locales of old release notes
        // would otherwise bury everything else.
        var untranslated: [String] = []
        var unfinished: [String: [String]] = [:]
        for locale in project.locales where locale.code != source {
            let unit = localizations[locale.code]?.stringUnit
            if unit?.value.isEmpty != false {
                untranslated.append(locale.code)
            } else if let unit, unit.state != StringCatalog.State.translated.rawValue {
                unfinished[unit.state.replacingOccurrences(of: "_", with: " "), default: []].append(locale.code)
            }
        }
        if !untranslated.isEmpty {
            problems.append(.warning("\(field.key): not translated in \(untranslated.joined(separator: ", "))"))
        }
        for (state, codes) in unfinished.sorted(by: { $0.key < $1.key }) {
            problems.append(.warning("\(field.key): \(state) in \(codes.joined(separator: ", ")), so it is not uploaded"))
        }
        return problems
    }

    /// Search already indexes the name and subtitle, so repeating their words,
    /// or a keyword, spends characters for nothing.
    func keywordProblems() -> [Problem] {
        var problems: [Problem] = []
        for locale in project.locales {
            guard let keywords = value(.keywords, locale: locale) else { continue }
            var seen: [String] = []
            for keyword in keywords.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
            where !keyword.isEmpty {
                if seen.contains(keyword) {
                    problems.append(.warning("keywords · \(locale.code): \(keyword) is listed twice"))
                } else {
                    seen.append(keyword)
                }
            }
            let titleWords = Set([value(.name, locale: locale), value(.subtitle, locale: locale)]
                .compactMap { $0?.lowercased() }
                .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) })
            for keyword in seen where titleWords.contains(keyword) {
                problems.append(.warning("keywords · \(locale.code): \(keyword) is already in the name or subtitle"))
            }
        }
        return problems
    }
}

public struct InvalidVersion: Error, CustomStringConvertible {
    public let version: String
    public var description: String { "\(version) is not a version: use digits and dots, like 1.9 or 1.9.1." }
}

public struct ReleaseExists: Error, CustomStringConvertible {
    public let version: String
    public var description: String { "What's New for \(version) is already in the catalog." }
}
