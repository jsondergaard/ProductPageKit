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

    @Test func aSceneLaunchesWithItsExtrasAndSaysReady() {
        #expect(AndroidScene.start(Shot("library", variant: "pro"), component: "com.example.app.dev/.MainActivity")
            == ["am", "start", "-W", "-S", "-n", "com.example.app.dev/.MainActivity", "--es", "productPageScene", "library",
                "--es", "productPageVariant", "pro"])
        #expect(AndroidScene.start("inbox", component: "a/.B").suffix(2) == ["productPageScene", "inbox"])
        #expect(AndroidScene.ready("inbox") == "ready inbox")
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
