public import Foundation

/// An Xcode String Catalog (`.xcstrings`): keys, each with a value per
/// language and a translation state. Read and written in Xcode's own layout,
/// so saving it from Xcode's editor and from ProductPageKit gives the same file.
public struct StringCatalog: Codable, Equatable, Sendable {
    public var sourceLanguage: String
    public var strings: [String: Entry]
    public var version: String

    public init(sourceLanguage: String, strings: [String: Entry] = [:]) {
        self.sourceLanguage = sourceLanguage
        self.strings = strings
        version = "1.0"
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var comment: String?
        public var extractionState: String?
        public var localizations: [String: Localization]?
        public var shouldTranslate: Bool?

        public init(comment: String?, shouldTranslate: Bool = true) {
            self.comment = comment
            extractionState = "manual"
            self.shouldTranslate = shouldTranslate ? nil : false
        }

        public var isTranslatable: Bool { shouldTranslate != false }
    }

    public struct Localization: Codable, Equatable, Sendable {
        public var stringUnit: StringUnit?
    }

    public struct StringUnit: Codable, Equatable, Sendable {
        public var state: String
        public var value: String

        public init(state: State, value: String) {
            self.state = state.rawValue
            self.value = value
        }
    }

    /// Translation states Xcode writes.
    public enum State: String, Sendable {
        case new
        case translated
        case needsReview = "needs_review"
    }

    /// The text for `language`, whatever its state.
    public func unit(_ key: String, language: String) -> StringUnit? {
        strings[key]?.localizations?[language]?.stringUnit
    }

    /// Sets a value. Changing the source language's value marks every
    /// translation of it as needing review.
    public mutating func set(_ value: String, for key: String, language: String, state: State = .translated) {
        var entry = strings[key] ?? Entry(comment: nil)
        var localizations = entry.localizations ?? [:]
        if language == sourceLanguage, let old = localizations[language]?.stringUnit?.value, old != value {
            for (other, localization) in localizations where other != language && localization.stringUnit != nil {
                localizations[other]?.stringUnit?.state = State.needsReview.rawValue
            }
        }
        localizations[language] = Localization(stringUnit: StringUnit(state: state, value: value))
        entry.localizations = localizations
        strings[key] = entry
    }

    public static func read(from url: URL) throws -> StringCatalog {
        try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: url))
    }

    /// Xcode's layout: sorted keys, two-space indent, `"key" : value`.
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}
