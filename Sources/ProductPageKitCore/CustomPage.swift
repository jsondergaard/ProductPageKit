/// A custom product page: its own screenshots, promotional text and search
/// keywords, for the link or ad that sends one audience to it. App Store
/// Connect takes iPhone and iPad screenshots for one, and nothing for a Mac
/// or an Apple TV.
///
/// Its copy is in the String Catalog: `page.<key>.promotionalText`, and a
/// caption for each shot under `page.<key>.screenshot.<shot>.` as the
/// store's screenshots have under `screenshot.<shot>.`.
public struct CustomPage: Sendable {
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

    /// The platforms App Store Connect takes screenshots for on a custom page.
    public static let platformsTaken: [Platform.Kind] = [.iPhone, .iPad]

    static func keyPrefix(_ key: String) -> String { "page.\(key)." }

    /// The caption a shot shows: the page's own, or the store's.
    public func captionSubject(_ shot: Shot) -> CaptionSubject {
        storeCaptions.contains(shot) ? .screenshot(shot) : .pageScreenshot(key, shot)
    }

    /// `page.pro.promotionalText`.
    public var promotionalText: Field {
        Field("\(Self.keyPrefix(key))promotionalText", title: "Promotional text on the \(key) page", maxLength: 170)
    }

    /// The `01_library-pro.png` App Store Connect is told a shot is called.
    public func fileName(for shot: Shot) -> String {
        guard let index = shots.firstIndex(of: shot) else { return shot.name }
        return String(format: "%02d_%@", index + 1, shot.name)
    }

    func problems(platforms configured: [Platform], storeShots: Set<Shot>) -> [String] {
        var problems: [String] = []
        let page = "the \(key) page"
        if key.isEmpty || key.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            problems.append("\(page)'s key must be letters, digits and hyphens")
        }
        if name.isEmpty { problems.append("\(page) has no name") }
        if platforms.isEmpty { problems.append("\(page) has no platforms") }
        for platform in platforms {
            if !Self.platformsTaken.contains(platform) {
                problems.append("\(page) lists the \(platform.name), and App Store Connect takes only iPhone and iPad screenshots for a custom page")
            } else if !configured.contains(where: { $0.kind == platform }) {
                problems.append("\(page) lists the \(platform.name), which is not a configured platform")
            }
        }
        if shots.isEmpty { problems.append("\(page) has no shots") }
        if shots.count > Platform.maximumShots {
            problems.append("\(page) lists \(shots.count) shots, and App Store Connect takes \(Platform.maximumShots)")
        }
        for shot in Set(shots) where shots.filter({ $0 == shot }).count > 1 {
            problems.append("\(page) lists \(shot) twice")
        }
        for shot in storeCaptions {
            if !shots.contains(shot) {
                problems.append("\(page) gives \(shot) the store's caption, and does not list it")
            } else if !storeShots.contains(shot) {
                problems.append("\(page) gives \(shot) the store's caption, and no platform's list has \(shot)")
            }
        }
        for keyword in keywords where keyword.isEmpty || keyword.contains(",") {
            problems.append("\(page) has the keyword \"\(keyword)\", and a keyword is one term without commas")
        }
        return problems
    }
}
