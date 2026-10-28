import CoreGraphics
import Foundation
import ProductPageKitCore
import ProductPageKitFrames
import Testing
@testable import ProductPageKitRunner

func project(locales: [String] = ["en", "da", "de", "fr", "es"]) -> Project {
    Project(
        name: "Example",
        bundleID: "com.example.app",
        xcode: .project("Example.xcodeproj", scheme: "Example"),
        locales: locales.map { StoreLocale($0, store: $0) },
        platforms: [
            .iPhone(shots: ["inbox", Shot("library", variant: "pro"), "quiet"]),
            .mac(window: CGSize(width: 1280, height: 800), shots: ["inbox", "setup"]),
        ],
        reviewScreenshots: [.inAppPurchases(test: "ExampleTests/Review/capture()")],
        metadata: Metadata(urls: URLs(marketing: "m", support: "s", privacy: "p"), copyright: "2026")
    )
}

/// Its first shot shows the Mac's home beside the iPhone's, with a badge.
struct DevicesFrames: FrameTheme {
    func sources(for frame: FrameSubject) -> [FrameSource] {
        guard frame.shot == "inbox" else { return [.capture(frame.shot, on: frame.platform)] }
        return frame.platform == .iPhone
            ? [.capture("inbox", on: .iPhone), .capture("home", on: .iPhone), .capture("home", on: .mac), .component("badge", on: .iPhone)]
            : [.capture("home", on: .mac)]
    }

    func render(_ shot: FramedShot, on canvas: Canvas) throws {}
}

@Suite struct CapturePlanTests {
    @Test func simulatorsGetOneWorkerForEveryFourCoresAndNoMoreThanLocales() throws {
        let example = project()
        let request = CaptureRequest(platforms: example.platforms, locales: example.locales)
        let plan = try CapturePlan(project: example, request: request, cores: 12)
        #expect(plan.targets[0].workers.map { $0.map(\.code) } == [["en", "fr"], ["da", "es"], ["de"]])
        #expect(plan.targets[1].workers.map { $0.map(\.code) } == [["en", "da", "de", "fr", "es"]])

        let few = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: Array(example.locales.prefix(2))), cores: 32)
        #expect(few.targets[0].workers.count == 2)
        let forced = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales, workers: 1), cores: 32)
        #expect(forced.targets[0].workers.count == 1)
        let small = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 2)
        #expect(small.targets[0].workers.count == 1)
    }

    @Test func localesAreDealtRoundRobin() {
        let locales = ["en", "da", "de", "fr", "es"].map { StoreLocale($0, store: $0) }
        #expect(CapturePlan.split(locales, into: 3).map { $0.map(\.code) } == [["en", "fr"], ["da", "es"], ["de"]])
        #expect(CapturePlan.split(Array(locales.prefix(1)), into: 3).map { $0.map(\.code) } == [["en"]])
    }

    @Test func filesAreNumberedInStoreOrder() throws {
        let example = project()
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 4)
        #expect(plan.targets[0].fileNames(in: example.locales[0]) == ["01_inbox.png", "02_library-pro.png", "03_quiet.png"])
        #expect(plan.targets.allSatisfy { $0.reviewScreenshots.count == 1 })
    }

    @Test func aSubsetKeepsNumbersForListedShotsAndNamesTheRest() throws {
        let example = project()
        let request = CaptureRequest(platforms: example.platforms, locales: example.locales, shots: ["quiet", "panel"])
        let plan = try CapturePlan(project: example, request: request, cores: 4)
        #expect(plan.targets[0].fileNames(in: example.locales[0]) == ["03_quiet.png", "panel.png"])
        #expect(plan.targets[1].fileNames(in: example.locales[0]) == ["quiet.png", "panel.png"])
        #expect(plan.targets.allSatisfy { $0.reviewScreenshots.isEmpty })
    }

    @Test func aPlatformWithoutShotsIsSkippedAndNoShotsAtAllIsAnError() throws {
        var example = project()
        example.platforms[1].shots = []
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 4)
        #expect(plan.targets.map(\.platform.id) == ["ios"])
        example.platforms[0].shots = []
        #expect(throws: RunnerError.self) {
            try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 4)
        }
    }

    func launches(_ shots: [Shot], components: [Component] = [], relaunching: Set<String> = [],
                  variantsRelaunch: Bool = false) -> [[String]] {
        CapturePlan.launches(shots, components: components, relaunching: relaunching, variantsRelaunch: variantsRelaunch).map { launch in
            launch.shots.map(\.name) + launch.components.map { "[\($0.fileName)]" }
        }
    }

    @Test func inProcessShotsShareALaunchAndRelaunchingOnesGetTheirOwn() {
        let shots: [Shot] = ["inbox", "panel", "detail", "settings"]
        #expect(launches(shots) == [["inbox", "panel", "detail", "settings"]])
        #expect(launches(shots, relaunching: ["panel", "settings"]) == [["inbox", "detail"], ["panel"], ["settings"]])
        // The first launch is started before the app has said which scenes
        // relaunch, so the group holding the first shot comes first.
        #expect(launches(["panel", "inbox", "detail"], relaunching: ["panel"]) == [["panel"], ["inbox", "detail"]])
    }

    /// An app that picks its data at launch draws each variant's scenes and
    /// components from a launch of its own.
    @Test func variantsTheAppDecidesAtLaunchGetALaunchEach() {
        let shots: [Shot] = ["home", Shot("library", variant: "pro"), "library", Shot("home", variant: "pro"), Shot("detail", variant: "smb")]
        let components: [Component] = ["sources", Component("sources", variant: "pro"), Component("sources", variant: "emby")]
        #expect(launches(shots, components: components) == [
            ["home", "library-pro", "library", "home-pro", "detail-smb", "[sources]", "[sources-pro]", "[sources-emby]"],
        ])
        #expect(launches(shots, components: components, variantsRelaunch: true) == [
            ["home", "library", "[sources]"], ["library-pro", "home-pro", "[sources-pro]"], ["detail-smb"], ["[sources-emby]"],
        ])
        #expect(launches([Shot("library", variant: "pro"), "home"], variantsRelaunch: true) == [["library-pro"], ["home"]])
        #expect(launches([], components: ["value-list"]) == [["[value-list]"]])
    }

    /// A theme that composes its frames has captured what it draws, from any
    /// platform, and the components it places.
    @Test func whatIsCapturedComesFromTheFrames() throws {
        var example = project(locales: ["en"])
        example.frames = DevicesFrames()
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 8)
        #expect(plan.targets[0].shots == ["inbox", "home", Shot("library", variant: "pro"), "quiet"])
        #expect(plan.targets[0].components == ["badge"])
        #expect(plan.targets[1].shots == ["home", "setup"])
        let subset = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales,
                                                                               shots: ["inbox"]), cores: 8)
        #expect(subset.targets.allSatisfy { $0.components.isEmpty })
    }

    /// Renders are taken in the primary locale alone, and only what the
    /// frames do not take already.
    @Test func rendersAreTakenInThePrimaryLocaleAlone() throws {
        var example = project()
        example.renders = [Render("inbox-site", .capture("inbox", on: .iPhone)), Render("player", .capture("player", on: .iPhone)),
                           Render("badge", .component(Component("badge", state: "on"), on: .iPhone))]
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 4)
        let iPhone = plan.targets[0]
        let english = example.locales[0], danish = example.locales[1]
        #expect(iPhone.shots(in: english) == ["inbox", Shot("library", variant: "pro"), "quiet", "player"])
        #expect(iPhone.shots(in: danish) == ["inbox", Shot("library", variant: "pro"), "quiet"])
        #expect(iPhone.components(in: english) == [Component("badge", state: "on")])
        #expect(iPhone.components(in: danish).isEmpty)
        #expect(plan.targets[1].primary == nil)
        #expect(plan.lines.contains("  components in en alone: badge@on"))

        let withoutEnglish = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms,
                                                                                         locales: [danish]), cores: 4)
        #expect(withoutEnglish.targets[0].primary == nil)
        let listed = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales,
                                                                                 shots: ["quiet"]), cores: 4)
        #expect(listed.targets[0].shots(in: english) == ["quiet"])
    }

    /// A test's screens run with the App Review screenshots, on the first
    /// worker in the primary locale, and only when that locale is captured.
    @Test func testRendersRunWithTheReviewScreenshots() throws {
        var example = project()
        let menu = "ExampleUITests/Renders/testMenus"
        example.renders = [Render("menu-audio", .test(menu, scene: Shot("menu", variant: "audio"), on: .iPhone)),
                           Render("menu-off", .test(menu, scene: Shot("menu", variant: "off"), on: .iPhone))]
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 4)
        #expect(plan.targets[0].tests == [example.reviewScreenshots[0].capture,
                                          TestCapture(test: menu, scene: Shot("menu", variant: "audio")),
                                          TestCapture(test: menu, scene: Shot("menu", variant: "off"))])
        #expect(plan.targets[1].tests == [example.reviewScreenshots[0].capture])
        #expect(plan.lines.contains("  menu (off) in en, from \(menu)"))

        let danish = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms,
                                                                                 locales: [example.locales[1]]), cores: 4)
        #expect(danish.targets[0].tests == [example.reviewScreenshots[0].capture])
    }

    @Test func aDryRunDescribesEveryLaunch() throws {
        let example = project(locales: ["en"])
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 8)
        #expect(plan.lines == [
            "iPhone 6.9\": the largest iPhone simulator, 1 worker",
            "  en: 01_inbox.png 02_library-pro.png 03_quiet.png",
            "  App Review screenshot of the in-app purchases, from ExampleTests/Review/capture()",
            "Mac: a 1280 × 800 window, 1 worker",
            "  en: 01_inbox.png 02_setup.png",
            "  App Review screenshot of the in-app purchases, from ExampleTests/Review/capture()",
        ])
    }

    @Test func aDryRunNamesTheFoldableIPhoneDuoIsCapturedOn() throws {
        var example = project(locales: ["en"])
        example.platforms = [.iPhoneDuo(shots: ["inbox"])]
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: example.platforms, locales: example.locales), cores: 8)
        #expect(plan.lines.first == "iPhone Duo: the largest foldable iPhone simulator, 1 worker")
    }
}
