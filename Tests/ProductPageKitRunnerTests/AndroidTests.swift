import CoreGraphics
import Foundation
import ProductPageKitCore
import ProductPageKitFrames
import Testing
@testable import ProductPageKitRunner

/// A feature graphic drawn from the phone's inbox.
struct GraphicFrames: FrameTheme {
    func sources(for frame: FrameSubject) -> [FrameSource] {
        frame.platform == .featureGraphic ? [.capture("inbox", on: .androidPhone)] : [.capture(frame.shot, on: frame.platform)]
    }

    func render(_ shot: FramedShot, on canvas: Canvas) throws {}
}

@Suite struct AndroidPlanTests {
    func example() -> Project {
        var example = project(locales: ["en", "da"])
        example.locales = [StoreLocale("en", store: "en-US"), StoreLocale("da", store: "da")]
        example.platforms += [.androidPhone(.emulator("phone"), shots: ["inbox", "settings"]), .androidTV(.device("tv:5555"), shots: ["inbox"]),
                              .featureGraphic()]
        example.frames = GraphicFrames()
        example.android = AndroidApp(build: [], apk: "app.apk", applicationID: "com.example.app.dev", activity: ".MainActivity")
        example.play = GooglePlay(packageName: "com.example.app")
        return example
    }

    /// One device each, no App Review screenshots, and the graphic drawn
    /// from the phone rather than captured.
    @Test func androidPlatformsTakeOneDeviceAndNoReviewScreenshots() throws {
        let example = example()
        #expect(example.problems().isEmpty)
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales),
                                   machine: Machine(cores: 16, memory: 64 << 30))
        #expect(plan.targets.map(\.platform.id) == ["ios", "macos", "android", "androidtv"])
        let phone = plan.targets[2]
        #expect(phone.workers == 1)
        #expect(phone.shots == ["inbox", "settings"])
        #expect(phone.reviewScreenshots.isEmpty)
        #expect(plan.targets[0].reviewScreenshots.count == 1)
        #expect(plan.lines.contains("Android phone: the emulator phone, 1 worker"))
        #expect(plan.lines.contains("Android TV: the device tv:5555, 1 worker"))
    }

    @Test func aSceneLaunchesWithItsExtras() {
        #expect(AndroidScene.start(Shot("library", variant: "pro"), activity: "com.example.app.dev/.MainActivity")
            == ["am", "start", "-W", "-S", "-n", "com.example.app.dev/.MainActivity", "--es", "productPageScene", "library",
                "--es", "productPageVariant", "pro"])
        #expect(AndroidScene.start(Shot("inbox"), activity: "a/.B").suffix(2) == ["productPageScene", "inbox"])
        #expect(AndroidScene.subject(Shot("library", variant: "pro")) == "library")
    }

    /// A component launches by its name, state and variant, and the app
    /// names it with its state.
    @Test func aComponentLaunchesWithItsExtras() {
        #expect(AndroidScene.start(Component("rail", state: "full", variant: "pro"), activity: "a/.B")
            == ["am", "start", "-W", "-S", "-n", "a/.B", "--es", "productPageComponent", "rail", "--es", "productPageComponentState", "full",
                "--es", "productPageVariant", "pro"])
        #expect(AndroidScene.start(Component("rail"), activity: "a/.B").suffix(3) == ["--es", "productPageComponent", "rail"])
        #expect(AndroidScene.subject(Component("rail", state: "full", variant: "pro")) == "rail@full")
        #expect(AndroidScene.subject(Component("rail")) == "rail")
    }

    /// The ready line names its subject, then each marked view's rect in the
    /// screen's pixels; any other line is not it.
    @Test func theReadyLineCarriesTheMarkedRects() throws {
        #expect(try AndroidScene.readiness("ready inbox", of: "inbox") == [])
        #expect(try AndroidScene.readiness("ready rail@full 0,120,1080,600  ", of: "rail@full")
            == [CGRect(x: 0, y: 120, width: 1080, height: 480)])
        #expect(try AndroidScene.readiness("ready inbox 10,20,30,40 50,60,70,80", of: "inbox")?.count == 2)
        #expect(try AndroidScene.readiness("ready inboxes", of: "inbox") == nil)
        #expect(try AndroidScene.readiness("ready rail@empty 0,0,1,1", of: "rail@full") == nil)
        #expect(try AndroidScene.readiness("loading inbox", of: "inbox") == nil)
        #expect(throws: RunnerError.self) { try AndroidScene.readiness("ready inbox 0,0,10", of: "inbox") }
        #expect(throws: RunnerError.self) { try AndroidScene.readiness("ready inbox 10,10,5,20", of: "inbox") }
    }

    /// A component is the part of the screen its rect covers, clipped to the
    /// screen.
    @Test func aComponentIsCroppedFromTheScreen() throws {
        let screen = try Frame(image: try #require(CGImage.rgba([UInt8](repeating: 200, count: 100 * 50 * 4), width: 100, height: 50)))
        let crop = try #require(try screen.cropped(to: CGRect(x: 10, y: 20, width: 30, height: 10)))
        #expect(crop.image.width == 30 && crop.image.height == 10)
        let clipped = try #require(try screen.cropped(to: CGRect(x: 90, y: 40, width: 30, height: 30)))
        #expect(clipped.image.width == 10 && clipped.image.height == 10)
        #expect(try screen.cropped(to: CGRect(x: 120, y: 0, width: 10, height: 10)) == nil)
    }

    /// Each platform captures the app it runs: the TV a build of its own, the
    /// phone the project's.
    @Test func aPlatformsOwnAppIsTheOneItRuns() throws {
        var example = example()
        let tv = AndroidApp(build: [], apk: "tv.apk", applicationID: "com.example.app.dev", activity: "com.example.tv.TvActivity")
        let index = try #require(example.platforms.firstIndex { $0.kind == .androidTV })
        example.platforms[index] = .androidTV(.device("tv:5555"), shots: ["inbox"], app: tv)
        #expect(example.problems().isEmpty)
        #expect(example.androidApp(for: try #require(example.platform(.androidTV)))?.apk == "tv.apk")
        #expect(example.androidApp(for: try #require(example.platform(.androidPhone)))?.apk == "app.apk")
    }

    @Test func demoModeShowsNineFortyOneOrTheRunsStart() {
        #expect(ScreenshotRunner.androidClock(.nineFortyOne, startedAt: Date()) == "0941")
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (2026, 11, 7, 18, 5)
        let start = Calendar.current.date(from: parts)!
        #expect(ScreenshotRunner.androidClock(.captureStart, startedAt: start) == "1805")
    }

    @Test func textSizesMapToAndroidsFontScale() {
        #expect(ContentSize.large.androidFontScale == "1.0")
        #expect(ContentSize.extraSmall.androidFontScale == "0.85")
        #expect(ContentSize.accessibilityExtraExtraExtraLarge.androidFontScale == "2.0")
    }

    /// The agreement with the app is part of a capture's stamp, so changing
    /// it takes everything again, as a new APK does.
    @Test func theStampFollowsTheContractAndTheAPK() throws {
        let example = example()
        let phone = try #require(example.platform(.androidPhone))
        let stamp = { (contract: String, build: String) in
            CaptureFingerprints.inputs(for: phone, contract: contract, build: build, device: "pixel", project: example, files: [],
                                       force: false).stamp
        }
        #expect(stamp(AndroidScene.contract, "a") == stamp(AndroidScene.contract, "a"))
        #expect(stamp(AndroidScene.contract, "a") != stamp(AndroidScene.contract, "b"))
        #expect(stamp(AndroidScene.contract, "a") != stamp("android scene 0", "a"))

        let apk = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).apk")
        try Data("apk".utf8).write(to: apk)
        defer { try? FileManager.default.removeItem(at: apk) }
        #expect(try CaptureFingerprints.digest(of: apk) == "dd37c2d7274f7ea982cb83390c36918fee9ce8889073c44b68cdc00bdb8c3e04")
    }

    @Test func theSDKIsFoundWhereTheEnvironmentSays() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sdk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "platform-tools"), withIntermediateDirectories: true)
        let adb = root.appending(path: "platform-tools/adb")
        try Data("#!/bin/sh\n".utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let sdk = try AndroidSDK.locate(environment: ["ANDROID_HOME": root.path])
        #expect(sdk.adb == adb.path)
        #expect(sdk.emulator == root.appending(path: "emulator/emulator").path)
    }
}
