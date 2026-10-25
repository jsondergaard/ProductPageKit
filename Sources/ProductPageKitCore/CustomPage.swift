/// A custom product page: its own screenshots, promotional text and search
/// keywords, for the link or ad that sends one audience to it. App Store
/// Connect takes iPhone and iPad screenshots for one, and nothing for a Mac
/// or an Apple TV.
///
/// Its copy is in the String Catalog: `page.<key>.promotionalText`, and a
/// caption for each shot under `page.<key>.screenshot.<shot>.` as the
/// store's screenshots have under `screenshot.<shot>.`.
public struct CustomPage: ShotListing {
    /// The catalog's name for it, and the command line's.
    public let key: String
    /// App Store Connect's name for it, which customers never see.
    public let name: String
    public let platforms: [Platform.Kind]
    /// In page order.
    public let shots: [Shot]
    /// Shots that show the store's caption, on purpose, rather than one
    /// written for the page.
    public let storeCaptions: [Shot]
    /// Terms of the app's own keywords the page is found by, in each locale
    /// whose keywords hold them. App Store Connect assigns a page only terms
    /// from the keywords of the app's live version.
    public let keywords: [String]

    public init(_ key: String, name: String, platforms: [Platform.Kind] = [.iPhone, .iPad], shots: [Shot],
                storeCaptions: [Shot] = [], keywords: [String] = []) {
        self.key = key
        self.name = name
        self.platforms = platforms
        self.shots = shots
        self.storeCaptions = storeCaptions
        self.keywords = keywords
    }

    public var list: ShotList { .customPage(key) }

    static func keyPrefix(_ key: String) -> String { "page.\(key)." }

    /// `page.pro.promotionalText`.
    public var promotionalText: Field {
        Field("\(Self.keyPrefix(key))promotionalText", title: "Promotional text on the \(key) page", maxLength: 170)
    }

    func problems(platforms configured: [Platform], storeShots: Set<Shot>) -> [String] {
        let page = "the \(key) page"
        var problems = problems(owner: page, key: key, name: name, storeShots: storeShots)
        if platforms.isEmpty { problems.append("\(page) has no platforms") }
        for platform in platforms {
            if !Platform.Kind.alternateScreenshotPlatforms.contains(platform) {
                problems.append("\(page) lists the \(platform.name), and App Store Connect takes only iPhone and iPad screenshots for a custom page")
            } else if !configured.contains(where: { $0.kind == platform }) {
                problems.append("\(page) lists the \(platform.name), which is not a configured platform")
            }
        }
        for keyword in keywords where keyword.isEmpty || keyword.contains(",") {
            problems.append("\(page) has the keyword \"\(keyword)\", and a keyword is one term without commas")
        }
        return problems
    }
}
