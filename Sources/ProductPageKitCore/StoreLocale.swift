import Foundation

/// A language the product page is written in.
///
/// `code` is what the String Catalog calls it, and the folder name under a
/// screenshot directory. `store` is App Store Connect's locale for it. They
/// differ where Apple's list does: `en` is `en-US`, `nb` is `no`. `app` is
/// the language the app runs in while it is captured, which differs for a
/// storefront the app has no localization of: Mexico's `es-MX` page shows
/// the app's Latin American Spanish, `es-419`.
public struct StoreLocale: Hashable, Sendable {
    public let code: String
    public let store: String
    public let app: String

    public init(_ code: String, store: String, app: String? = nil) {
        self.code = code
        self.store = store
        self.app = app ?? code
    }

    /// `en_US` for `en-US`: the region a StoreKit configuration file names,
    /// and the one a capture launches the app in.
    public var localeIdentifier: String { store.replacingOccurrences(of: "-", with: "_") }

    /// Google Play's language for the listing App Store Connect calls
    /// `store`, or nil for one Google Play has no listing language for.
    public var playLanguage: String? { Self.playLanguages[store] }

    /// App Store Connect's locales and the Google Play languages they are
    /// listed in. Google Play names most with a region, Hebrew by its old
    /// code, and Latin American Spanish as one listing.
    static let playLanguages: [String: String] = [
        "ar-SA": "ar", "bn-BD": "bn-BD", "ca": "ca", "cs": "cs-CZ", "da": "da-DK", "de-DE": "de-DE", "el": "el-GR",
        "en-AU": "en-AU", "en-CA": "en-CA", "en-GB": "en-GB", "en-US": "en-US", "es-ES": "es-ES", "es-MX": "es-419",
        "fi": "fi-FI", "fr-CA": "fr-CA", "fr-FR": "fr-FR", "gu-IN": "gu", "he": "iw-IL", "hi": "hi-IN", "hr": "hr",
        "hu": "hu-HU", "id": "id", "it": "it-IT", "ja": "ja-JP", "kn-IN": "kn-IN", "ko": "ko-KR", "ml-IN": "ml-IN",
        "mr-IN": "mr-IN", "ms": "ms", "nl-NL": "nl-NL", "no": "no-NO", "pa-IN": "pa", "pl": "pl-PL", "pt-BR": "pt-BR",
        "pt-PT": "pt-PT", "ro": "ro", "ru": "ru-RU", "sk": "sk", "sl-SI": "sl", "sv": "sv-SE", "ta-IN": "ta-IN",
        "te-IN": "te-IN", "th": "th", "tr": "tr-TR", "uk": "uk", "ur-PK": "ur", "vi": "vi", "zh-Hans": "zh-CN",
        "zh-Hant": "zh-TW",
    ]

    /// Whether the store's language is written right to left, as a theme
    /// mirrors its layout for.
    public var isRightToLeft: Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }
}
