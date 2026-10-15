/// A piece of App Store copy kept in the store's String Catalog: a field App
/// Store Connect holds, or a line of a screenshot's or video's caption.
///
/// The caps are Apple's. App Store Connect enforces them at submission against
/// the whole update, and the rejection names neither the field nor the locale,
/// so `metadata check` holds every value to them first.
public struct Field: Hashable, Sendable {
    /// The catalog key.
    public let key: String
    /// What App Store Connect calls it.
    public let title: String
    /// Apple's cap, or nil for a caption, which is drawn rather than uploaded.
    public let maxLength: Int?
    /// False for fields App Store Connect keeps once, in the primary language.
    public let isTranslatable: Bool
    /// Whether the source language must have a value.
    public let isRequired: Bool

    init(_ key: String, title: String, maxLength: Int?, translatable: Bool = true, required: Bool = true) {
        self.key = key
        self.title = title
        self.maxLength = maxLength
        isTranslatable = translatable
        isRequired = required
    }

    /// The comment a new catalog entry gets, which Xcode's editor shows
    /// beside the key.
    public var comment: String { maxLength.map { "\(title), up to \($0) characters." } ?? "\(title)." }

    /// One line of a caption: `screenshot.inbox.headline`. Only the headline
    /// is required.
    public static func caption(_ subject: CaptionSubject, _ line: Caption.Line) -> Field {
        Field("\(subject.key).\(line.rawValue)", title: "\(line.rawValue.capitalized) on \(subject.title)", maxLength: nil,
              required: line == .headline)
    }

    public static let name = Field("name", title: "App name", maxLength: 30)
    public static let subtitle = Field("subtitle", title: "Subtitle", maxLength: 30)
    public static let keywords = Field("keywords", title: "Keywords, comma-separated", maxLength: 100)
    public static let promotionalText = Field("promotionalText", title: "Promotional text", maxLength: 170)
    public static let description = Field("description", title: "Description", maxLength: 4000)
    public static let reviewNotes = Field("reviewNotes", title: "App Review notes, not translated", maxLength: 4000,
                                          translatable: false)
    public static let productReviewNote = Field("productReviewNote", title: "Every in-app product's App Review note, not translated",
                                                     maxLength: 4000, translatable: false)

    /// What's New for one version: `whatsNew.1.2`.
    public static func whatsNew(_ version: String) -> Field {
        Field(whatsNewPrefix + version, title: "What's New in \(version)", maxLength: 4000)
    }

    static let whatsNewPrefix = "whatsNew."

    /// The version a What's New key is for, or nil for any other key.
    public static func version(ofWhatsNew key: String) -> String? {
        guard key.hasPrefix(whatsNewPrefix) else { return nil }
        let version = String(key.dropFirst(whatsNewPrefix.count))
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return version
    }

    /// The product page's text, in App Store Connect's order.
    public static let listing: [Field] = [.name, .subtitle, .keywords, .promotionalText, .description]
}
