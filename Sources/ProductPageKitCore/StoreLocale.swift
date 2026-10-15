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

    /// Whether the store's language is written right to left, as a theme
    /// mirrors its layout for.
    public var isRightToLeft: Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }
}
