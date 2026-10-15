import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ProductPageKit
import ProductPageKitASC

/// Prints into a list and answers prompts from a queue.
final class RecordingConsole: Console, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var answers: [String]
    let isInteractive: Bool

    init(answers: [String] = [], interactive: Bool = true) {
        self.answers = answers
        isInteractive = interactive
    }

    func print(_ line: String) { lock.withLock { lines.append(line) } }

    func readLine(prompt: String) -> String? {
        lock.withLock {
            lines.append(prompt)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    var output: String { lock.withLock { lines.joined(separator: "\n") } }
}

/// A repository on disk with the copy a project needs, a cache beside it,
/// and a session over them that talks to a fake App Store Connect.
final class Fixture {
    /// Which themes the project has.
    struct Themes: OptionSet {
        let rawValue: Int
        static let frames = Themes(rawValue: 1)
        static let videos = Themes(rawValue: 2)
    }

    let root: URL
    let fake: FakeAppStoreConnect
    var console = RecordingConsole()
    var environment: [String: String] = [
        "DEMO_EMAIL": "review@example.com", "DEMO_CODE": "s3cret-code",
        "CONTACT_FIRST_NAME": "Ada", "CONTACT_EMAIL": "ada@example.com",
    ]

    var project: Project
    let themes: Themes

    init(fake: FakeAppStoreConnect = .seeded(), themes: Themes = []) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        self.fake = fake
        self.themes = themes
        project = Project(
            name: "Example",
            bundleID: "com.example.app",
            locales: [StoreLocale("en", store: "en-US"), StoreLocale("da", store: "da")],
            platforms: [.iPhone(shots: ["home", "list"]), .mac(window: CGSize(width: 1280, height: 800), shots: ["home"])],
            reviewScreenshots: [.inAppPurchases(test: "ExampleTests/Review/capture()")],
            frames: themes.contains(.frames) ? SampleFrames() : nil,
            videos: themes.contains(.videos) ? SampleMotion(shots: ["home", "list"]) : nil,
            metadata: Metadata(
                urls: URLs(marketing: "https://example.com", support: "https://example.com/support",
                           privacy: "https://example.com/privacy"),
                copyright: "2026 Example",
                requiredLinks: [.description: ["https://example.com/terms"]],
                fallbackKeywords: "fallback",
                reviewAccount: .environment(name: "DEMO_EMAIL", password: "DEMO_CODE"),
                reviewContact: .environment(prefix: "CONTACT_")
            ),
            products: Products(
                source: .command("cat catalogue.json"),
                serverNotifications: URL(string: "https://example.com/v1/notifications"),
                storeKit: StoreKitFile(path: "Example.storekit", teamID: "TEAM123456")
            )
        )
        try writeCatalog()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var session: Session {
        let fake = fake
        return Session(project: project, root: root, environment: Environment(values: environment), console: console,
                       cache: cache) {
            AppStoreConnect(credentials: Credentials(issuerID: "issuer", keyID: "KEY", privateKey: P256.Signing.PrivateKey()),
                            transport: fake)
        }
    }

    func write(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    func write(_ data: Data, to path: String) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    /// Inside the repository folder, so `again()` copies it and `deinit`
    /// removes it.
    var cache: Cache { Cache(bundleID: project.bundleID, root: root.appending(path: "cache")) }

    func writeReviewScreenshot(_ data: Data) throws {
        let file = cache.review(project.platforms[0], .inAppPurchases)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    let en = StoreLocale("en", store: "en-US")
    let da = StoreLocale("da", store: "da")

    func writeCatalog() throws {
        var copy = StoreCopy(project: project, catalog: StringCatalog(sourceLanguage: "en"))
        let values: [(Field, String, String)] = [
            (.name, "Example", "Eksempel"),
            (.subtitle, "Alerts that ring", "Alarmer der ringer"),
            (.keywords, "push,pager", "push,personsøger"),
            (.promotionalText, "New in 1.2.", "Nyt i 1.2."),
            (.description, "Terms: https://example.com/terms", "Vilkår: https://example.com/terms"),
            (.whatsNew("1.2"), "Faster.", "Hurtigere."),
        ]
        for (field, english, danish) in values {
            copy.set(english, field: field, locale: en)
            copy.set(danish, field: field, locale: da)
        }
        for subject in project.captionSubjects {
            copy.set("Headline \(subject)", field: .caption(subject, .headline), locale: en)
            copy.set("Overskrift \(subject)", field: .caption(subject, .headline), locale: da)
        }
        copy.set("Sign in with the demo account.", field: .reviewNotes, locale: en)
        copy.set("Buy with the demo account.", field: .productReviewNote, locale: en)
        try copy.write(root: root)
        try write("""
            {"subscriptionGroups": [{
              "referenceName": "Example Plus",
              "localizations": {"en": {"name": "Example Plus"}, "da": {"name": "Example Plus"}},
              "subscriptions": [
                {"productID": "com.example.plus.monthly", "referenceName": "Plus Monthly", "level": 1, "period": "P1M",
                 "price": "4.99", "localizations": {"en": {"name": "Plus", "description": "Every month."}}},
                {"productID": "com.example.plus.annual", "referenceName": "Plus Annual", "level": 1, "period": "P1Y",
                 "price": "49.00", "localizations": {"en": {"name": "Plus", "description": "Every year."},
                                                     "da": {"name": "Plus", "description": "Hvert år."}}}
              ]
            }],
            "inAppPurchases": [
              {"productID": "com.example.lifetime", "referenceName": "Lifetime", "kind": "NON_CONSUMABLE", "price": "99.99",
               "familySharable": true, "localizations": {"en": {"name": "Lifetime", "description": "Every alert, for good."}}}
            ]}
            """, to: "catalogue.json")
    }

    var copy: StoreCopy { get throws { try StoreCopy.load(project, root: root) } }

    func updateCopy(_ change: (inout StoreCopy) throws -> Void) throws {
        var copy = try self.copy
        try change(&copy)
        try copy.write(root: root)
    }

    /// A capture of `shot`, one colour at the size App Store Connect takes,
    /// so it is a screenshot as it is.
    func writeCapture(_ kind: Platform.Kind, _ locale: StoreLocale, _ shot: Shot, shade: UInt8 = 128) throws {
        let platform = try #require(project.platform(kind))
        let canvas = Canvas(size: kind.screenshotSize)
        let value = CGFloat(shade) / 255
        canvas.context.setFillColor(CGColor(srgbRed: value, green: value * 0.8, blue: 1 - value, alpha: 1))
        canvas.context.fill(canvas.bounds)
        let url = cache.raw(platform, locale).appending(path: "\(platform.fileName(for: shot)).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ImageFormat.png.encode(canvas.image()).write(to: url)
    }

    /// Everything the frames and videos draw on every platform in every
    /// locale, and the renders in the primary one, each capture its own
    /// colour.
    func writeCaptures() throws {
        for platform in project.platforms {
            for (index, locale) in project.locales.enumerated() {
                let primary = locale == project.primaryLocale
                let shots = project.captures(on: platform.kind)
                    + (primary ? project.renderCaptures(on: platform.kind) + project.renderTests(on: platform.kind).map(\.scene) : [])
                for (position, shot) in shots.enumerated() {
                    try writeCapture(platform.kind, locale, shot, shade: UInt8(40 + 60 * position + 20 * index))
                }
                for component in project.components(on: platform.kind) + (primary ? project.renderComponents(on: platform.kind) : []) {
                    let canvas = Canvas(size: CGSize(width: 300, height: 200))
                    canvas.context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 1))
                    canvas.context.fill(canvas.bounds.insetBy(dx: 20, dy: 20))
                    let url = cache.component(platform, locale, component)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ImageFormat.png.encode(canvas.image()).write(to: url)
                }
            }
        }
    }

    /// A fixture over the same App Store Connect, with a fresh console.
    func again() throws -> Fixture {
        let next = try Fixture(fake: fake, themes: themes)
        try FileManager.default.removeItem(at: next.root)
        try FileManager.default.copyItem(at: root, to: next.root)
        return next
    }

    /// The files in a cache folder, the index aside.
    func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "index.json" }.sorted()
    }
}
