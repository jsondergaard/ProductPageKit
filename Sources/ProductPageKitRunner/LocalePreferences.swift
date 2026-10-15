import ProductPageKitCore

/// The `AppleLanguages` and `AppleLocale` preferences that put an app, or a
/// whole simulator, in a store locale.
struct LocalePreferences: Equatable, Sendable {
    let languages: [String]
    let locale: String

    static let languagesKey = "AppleLanguages"
    static let localeKey = "AppleLocale"

    init(_ locale: StoreLocale) {
        languages = [locale.app]
        self.locale = locale.localeIdentifier
    }

    /// The pair a preferences dictionary holds, when it holds both.
    init?(_ preferences: [String: Any]) {
        guard let languages = preferences[Self.languagesKey] as? [String],
              let locale = preferences[Self.localeKey] as? String
        else { return nil }
        self.languages = languages
        self.locale = locale
    }

    /// `preferences` with this pair in place of its own, and every other key
    /// kept.
    func applied(to preferences: [String: Any]) -> [String: Any] {
        preferences.merging([Self.languagesKey: languages, Self.localeKey: locale]) { _, new in new }
    }

    /// The pair as argument-domain overrides for one launch of an app.
    var launchArguments: [String] {
        ["-\(Self.languagesKey)", "(\(languages.joined(separator: ", ")))", "-\(Self.localeKey)", locale]
    }
}
