import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKit
import ProductPageKitRunner

/// Captures `Fixtures/SampleAndroidApp`, built with the SDK's own tools, on
/// this Mac's Android emulators: the first phone AVD, and the first TV AVD
/// when there is one. Each is booted without a window for the run and shut
/// down after it. Skipped on a Mac without an AVD.
@Suite(.serialized, .enabled(if: LocalAVDs.phone != nil))
struct AndroidCaptureTests {
    static let en = StoreLocale("en", store: "en-US")
    static let da = StoreLocale("da", store: "da")

    static let project: Project = {
        var platforms: [Platform] = [.androidPhone(.emulator(LocalAVDs.phone ?? ""), shots: ["inbox", Shot("detail", variant: "blue")])]
        if let tv = LocalAVDs.tv { platforms.append(.androidTV(.emulator(tv), shots: ["inbox", "settings"])) }
        return Project(
            name: "Sample", bundleID: "com.productpagekit.sample.android", locales: [en, da], appearance: .dark, platforms: platforms,
            renders: [Render("card@blue", .component(Component("card", state: "blue"), on: .androidPhone))],
            metadata: Metadata(urls: URLs(marketing: "https://example.com", support: "https://example.com/support",
                                          privacy: "https://example.com/privacy"), copyright: "2026 Example"),
            android: AndroidApp(build: ["sh Fixtures/SampleAndroidApp/build.sh .build/sample-android"],
                                apk: ".build/sample-android/app.apk", applicationID: "com.productpagekit.sample",
                                activity: ".MainActivity"),
            play: GooglePlay(packageName: "com.productpagekit.sample")
        )
    }()

    @Test func capturesEachSceneInEachLocaleThenKeepsThemUntilForced() async throws {
        let cache = Cache(bundleID: Self.project.bundleID,
                          root: FileManager.default.temporaryDirectory.appending(path: "ProductPageKitAndroid-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let console = RecordingConsole()
        let session = Session(project: Self.project, root: CaptureTests.packageRoot, environment: Environment(values: [:]),
                              console: console, cache: cache,
                              connectPlay: { throw Stopped(description: "no Google Play in capture tests") }) {
            throw Stopped(description: "no App Store Connect in capture tests")
        }
        let first = try #require(try await Commands.captureScreenshots(session, platforms: "", locales: "", shots: "", workers: nil,
                                                                       force: true, dryRun: false))
        let perLocale = Self.project.platforms.map(\.shots.count).reduce(0, +)
        #expect(first.shots.count == perLocale * 2)
        #expect(first.components.count == 1)
        let phone = try #require(Self.project.platform(.androidPhone))
        let inbox = try CGImage.read(from: cache.capture(phone, Self.en, "inbox"))
        // The emulator's own screen, whatever its size.
        #expect(inbox.width > 0 && inbox.width < inbox.height)
        // The app ran in each locale: Danish names its language on screen.
        let danish = try Data(contentsOf: cache.capture(phone, Self.da, "inbox"))
        #expect(try Data(contentsOf: cache.capture(phone, Self.en, "inbox")) != danish)
        // The component is the card cut out of the screen it was shown on.
        let card = try CGImage.read(from: cache.component(phone, Self.en, Component("card", state: "blue")))
        #expect(card.width == 600 && card.height == 300)
        if let tv = Self.project.platform(.androidTV) {
            let screen = try CGImage.read(from: cache.capture(tv, Self.en, "settings"))
            #expect(screen.width > screen.height)
        }

        let second = try #require(try await Commands.captureScreenshots(session, platforms: "", locales: "", shots: "", workers: nil,
                                                                        force: false, dryRun: false))
        #expect(second.shots.isEmpty)
        #expect(second.unchanged == perLocale * 2 + 1)
        #expect(console.output.contains("Everything is up to date"))
    }
}

/// This Mac's Android Virtual Devices.
enum LocalAVDs {
    /// The first AVD whose system image's tag `matches`, by name.
    static func first(_ matches: (String) -> Bool) -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/avd")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".ini") }.sorted()
        for name in names {
            let config = folder.appending(path: name.replacingOccurrences(of: ".ini", with: ".avd/config.ini"))
            let tag = ((try? String(contentsOf: config, encoding: .utf8)) ?? "").split(separator: "\n")
                .first { $0.hasPrefix("tag.id=") }.map { String($0.dropFirst("tag.id=".count)) }
            if let tag, matches(tag) { return String(name.dropLast(".ini".count)) }
        }
        return nil
    }

    static let phone = first { !$0.contains("tv") && !$0.contains("wear") }
    static let tv = first { $0.contains("tv") }
}
