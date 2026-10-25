import ArgumentParser
import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKit
@testable import ProductPageKitASC
@testable import ProductPageKitCore

/// `experiments push` against an in-memory App Store Connect: an experiment
/// is found by name or made, never started or submitted, and each
/// treatment's screenshots kept in step in every locale on iPhone and iPad.
@Suite struct ExperimentsTests {
    static let iPhone = "APP_IPHONE_67"
    static let iPad = "APP_IPAD_PRO_3GEN_129"

    static func experiment(treatments: [Treatment]? = nil, trafficProportion: Int = 50) -> Experiment {
        Experiment("story", name: "Story test", trafficProportion: trafficProportion, treatments: treatments ?? [
            Treatment("story", name: "Story set", shots: ["list", "home"], storeCaptions: ["home"]),
        ])
    }

    /// Both devices, and the experiment; the sample theme frames the captures.
    func fixture(_ experiment: Experiment = experiment(), locales: [StoreLocale] = []) throws -> Fixture {
        let fixture = try Fixture(themes: .frames)
        fixture.project.platforms = [.iPhone(shots: ["home", "list"]), .iPad(shots: ["home", "list"]),
                                     .mac(window: CGSize(width: 1280, height: 800), shots: ["home"])]
        fixture.project.locales += locales
        fixture.project.experiments = [experiment]
        try fixture.writeCatalog()
        try fixture.writeCaptures()
        return fixture
    }

    func push(_ fixture: Fixture, experiments: String = "", locales: String = "", options: WriteOptions = apply) async throws {
        try await Commands.pushExperiments(fixture.session, experiments: experiments, locales: locales, options: options)
    }

    func resource(_ fixture: Fixture, _ type: String, _ name: String) throws -> FakeAppStoreConnect.Resource {
        try #require(fixture.fake.all(type).first { $0.attributes["name"] as? String == name })
    }

    /// The file names in a treatment's set for a display type, in order.
    func shots(_ fixture: Fixture, treatment name: String, locale: String, display: String) throws -> [String?] {
        let treatment = try resource(fixture, "appStoreVersionExperimentTreatments", name)
        let localization = try #require(fixture.fake.all("appStoreVersionExperimentTreatmentLocalizations").first {
            $0.attributes["locale"] as? String == locale && $0.relationships["appStoreVersionExperimentTreatment"]?.id == treatment.id
        })
        let set = try #require(fixture.fake.all("appScreenshotSets").first {
            $0.relationships["appStoreVersionExperimentTreatmentLocalization"]?.id == localization.id
                && $0.attributes["screenshotDisplayType"] as? String == display
        })
        return fixture.fake.screenshots(inSet: set.id).map { $0.attributes["fileName"] as? String }
    }

    func uploads(_ fixture: Fixture) -> Int { fixture.fake.writes.filter { $0 == "POST /v1/appScreenshots" }.count }

    @Test func anExperimentIsMadeWithItsTreatmentFilledInEveryLocaleAndNeverStarted() async throws {
        let fixture = try fixture()
        try await push(fixture)

        let experiment = try resource(fixture, "appStoreVersionExperiments", "Story test")
        #expect(experiment.attributes["platform"] as? String == "IOS")
        #expect(experiment.attributes["trafficProportion"] as? Int == 50)
        #expect(experiment.attributes["state"] as? String == "PREPARE_FOR_SUBMISSION")
        #expect(experiment.attributes["startDate"] == nil && experiment.attributes["started"] == nil)
        #expect(experiment.relationships["app"]?.id == "app")
        let treatment = try resource(fixture, "appStoreVersionExperimentTreatments", "Story set")
        #expect(treatment.relationships["appStoreVersionExperiment"]?.id == experiment.id)
        #expect(fixture.fake.all("appStoreVersionExperimentTreatmentLocalizations").compactMap { $0.attributes["locale"] as? String }.sorted()
            == ["da", "en-US"])
        for locale in ["en-US", "da"] {
            for display in [Self.iPhone, Self.iPad] {
                #expect(try shots(fixture, treatment: "Story set", locale: locale, display: display) == ["01_list.png", "02_home.png"])
            }
        }
        // Nothing else was written: no state change, no submission, and no
        // default page, which the control stays.
        #expect(fixture.fake.writes.filter { !$0.hasPrefix("POST") && !$0.contains("appScreenshots") } == [])
        #expect(Set(fixture.fake.writes.filter { $0.hasPrefix("POST") }.map { $0.split(separator: "/").last! })
            == ["appStoreVersionExperiments", "appStoreVersionExperimentTreatments", "appStoreVersionExperimentTreatmentLocalizations",
                "appScreenshotSets", "appScreenshots"])
        #expect(fixture.fake.all("appStoreVersionLocalizations").isEmpty)
        #expect(fixture.console.output.contains("create  Story test experiment"))
        #expect(fixture.console.output.contains("not started, and not submitted for review"))
        // Only the treatment is framed: two locales, two devices, two shots.
        #expect(try fixture.files(in: fixture.cache.framed).count == 8)
    }

    @Test func aSecondPushFindsNothingToChange() async throws {
        let fixture = try fixture()
        try await push(fixture)
        fixture.fake.clearWrites()
        let second = try fixture.again()
        second.project = fixture.project
        try await push(second)
        #expect(second.console.output.contains("Nothing to change."))
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func aChangedScreenshotIsTheOnlyOneReplaced() async throws {
        let fixture = try fixture()
        try await push(fixture)
        let before = fixture.fake.all("appScreenshots").count
        try fixture.writeCapture(.iPhone, fixture.da, "list", shade: 250)
        fixture.fake.clearWrites()
        fixture.console = RecordingConsole()

        try await push(fixture)

        #expect(uploads(fixture) == 1)
        #expect(fixture.fake.writes.filter { $0.hasPrefix("DELETE /v1/appScreenshots/") }.count == 1)
        #expect(fixture.fake.writes.filter { $0.hasPrefix("POST") }.count == 1)
        #expect(fixture.fake.all("appScreenshots").count == before)
        #expect(try shots(fixture, treatment: "Story set", locale: "da", display: Self.iPhone) == ["01_list.png", "02_home.png"])
        #expect(fixture.console.output.contains("upload  Story test experiment · Story set · da · iPhone 6.9\""))
        #expect(!fixture.console.output.contains("upload  Story test experiment · Story set · da · iPad"))
        #expect(!fixture.console.output.contains("en-US"))
    }

    @Test(arguments: ["WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "APPROVED", "COMPLETED", "STOPPED"])
    func anExperimentInReviewOrRunningIsRefusedWhole(state: String) async throws {
        let fixture = try fixture()
        try await push(fixture)
        let experiment = try resource(fixture, "appStoreVersionExperiments", "Story test")
        fixture.fake.change(experiment.id, ["state": state])
        try fixture.writeCapture(.iPhone, fixture.da, "list", shade: 250)
        fixture.project.experiments[0] = Self.experiment(trafficProportion: 10)
        fixture.fake.clearWrites()

        let error = await #expect(throws: ExperimentNotEditable.self) { try await push(fixture) }

        #expect(error?.description.hasPrefix("The Story test experiment is \(state)") == true)
        #expect(error?.description.contains("Stop or delete it in App Store Connect, or give the experiment another name.") == true)
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func anExperimentWithAStartDateIsRefusedWhateverItsState() async throws {
        let fixture = try fixture()
        try await push(fixture)
        let experiment = try resource(fixture, "appStoreVersionExperiments", "Story test")
        fixture.fake.change(experiment.id, ["startDate": "2026-10-01T10:00:00Z"])
        try fixture.writeCapture(.iPhone, fixture.da, "list", shade: 250)
        fixture.fake.clearWrites()

        let error = await #expect(throws: ExperimentNotEditable.self) { try await push(fixture) }

        #expect(error?.description.hasPrefix("The Story test experiment is PREPARE_FOR_SUBMISSION since 2026-10-01") == true)
        #expect(fixture.fake.writes.isEmpty)
    }

    /// Refusing one refuses all, so nothing is half-written.
    @Test func oneRefusedExperimentStopsTheOthersToo() async throws {
        let fixture = try fixture()
        try await push(fixture)
        let experiment = try resource(fixture, "appStoreVersionExperiments", "Story test")
        fixture.fake.change(experiment.id, ["state": "IN_REVIEW"])
        fixture.project.experiments = [
            Experiment("other", name: "Other test", trafficProportion: 20, treatments: [Treatment("other", name: "Other", shots: ["home"])]),
            Self.experiment(),
        ]
        try fixture.writeCatalog()
        try fixture.writeCaptures()
        fixture.fake.clearWrites()

        await #expect(throws: ExperimentNotEditable.self) { try await push(fixture) }
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test(arguments: ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "REJECTED", "DEVELOPER_REJECTED"])
    func anExperimentNotYetApprovedIsEditedInPlace(state: String) async throws {
        let fixture = try fixture()
        try await push(fixture)
        let experiment = try resource(fixture, "appStoreVersionExperiments", "Story test")
        fixture.fake.change(experiment.id, ["state": state])
        try fixture.writeCapture(.iPad, fixture.en, "home", shade: 250)
        fixture.fake.clearWrites()

        try await push(fixture)

        #expect(uploads(fixture) == 1)
        #expect(fixture.fake.all("appStoreVersionExperiments").count == 1)
        #expect(fixture.fake.resource(experiment.id)?.attributes["state"] as? String == state)
    }

    @Test func aChangedShareIsTheOnlyThingSentToTheExperiment() async throws {
        let fixture = try fixture()
        try await push(fixture)
        fixture.project.experiments = [Self.experiment(trafficProportion: 30)]
        fixture.fake.clearWrites()

        try await push(fixture)

        let experiment = try resource(fixture, "appStoreVersionExperiments", "Story test")
        #expect(fixture.fake.writes == ["PATCH /v2/appStoreVersionExperiments/\(experiment.id)"])
        #expect(experiment.attributes["trafficProportion"] as? Int == 30)
        #expect(experiment.attributes["state"] as? String == "PREPARE_FOR_SUBMISSION")
        #expect(fixture.console.output.contains("trafficProportion: 50 → 30"))
    }

    @Test func anExperimentAlreadyThereIsFoundByNameAndGetsOnlyWhatItLacks() async throws {
        let fixture = try fixture()
        let id = fixture.fake.add("appStoreVersionExperiments", ["name": "Story test", "platform": "IOS", "trafficProportion": 50,
                                                                 "state": "PREPARE_FOR_SUBMISSION"], relationships: ["app": ("apps", "app")])
        fixture.fake.add("appStoreVersionExperiments", ["name": "Another", "state": "APPROVED"], relationships: ["app": ("apps", "app")])

        try await push(fixture)

        #expect(fixture.fake.all("appStoreVersionExperiments").count == 2)
        #expect(!fixture.fake.writes.contains("POST /v2/appStoreVersionExperiments"))
        #expect(try resource(fixture, "appStoreVersionExperimentTreatments", "Story set").relationships["appStoreVersionExperiment"]?.id == id)
    }

    @Test func aLocaleAddedLaterGetsALocalizationInTheTreatmentAlreadyThere() async throws {
        let fixture = try fixture()
        try await push(fixture)
        fixture.project.locales.append(StoreLocale("de", store: "de-DE"))
        try fixture.writeCatalog()
        try fixture.writeCaptures()
        fixture.fake.clearWrites()
        fixture.console = RecordingConsole()

        try await push(fixture)

        #expect(fixture.fake.writes.filter { $0.hasPrefix("POST") && !$0.contains("appScreenshot") }
            == ["POST /v1/appStoreVersionExperimentTreatmentLocalizations"])
        #expect(fixture.fake.all("appStoreVersionExperimentTreatments").count == 1)
        for display in [Self.iPhone, Self.iPad] {
            #expect(try shots(fixture, treatment: "Story set", locale: "de-DE", display: display) == ["01_list.png", "02_home.png"])
        }
        #expect(!fixture.console.output.contains("en-US"))
    }

    @Test func onlyTheNamedExperimentsArePushed() async throws {
        let fixture = try fixture()
        fixture.project.experiments.append(
            Experiment("other", name: "Other test", trafficProportion: 20, treatments: [Treatment("other", name: "Other", shots: ["home"])])
        )
        try fixture.writeCatalog()

        try await push(fixture, experiments: "other")

        #expect(fixture.fake.all("appStoreVersionExperiments").compactMap { $0.attributes["name"] as? String } == ["Other test"])
        #expect(fixture.fake.all("appStoreVersionExperimentTreatments").compactMap { $0.attributes["name"] as? String } == ["Other"])
        // Only the named experiment's treatment is framed.
        #expect(try fixture.files(in: fixture.cache.framed).count == 4)
    }

    @Test func anUnknownExperimentIsNamedWithTheOnesThereAre() async throws {
        let fixture = try fixture()
        let error = await #expect(throws: Stopped.self) { try await push(fixture, experiments: "lead") }
        #expect(error?.description == "Unknown experiment lead. This project has story.")
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func threeTreatmentsInThreeLocalesAreAllFilled() async throws {
        let german = StoreLocale("de", store: "de-DE")
        let fixture = try fixture(Self.experiment(treatments: [
            Treatment("one", name: "One", shots: ["home"]),
            Treatment("two", name: "Two", shots: ["list", "home"], storeCaptions: ["home"]),
            Treatment("three", name: "Three", shots: ["home", "list"], storeCaptions: ["list"]),
        ]), locales: [german])

        try await push(fixture)

        #expect(fixture.fake.all("appStoreVersionExperimentTreatments").count == 3)
        #expect(fixture.fake.all("appStoreVersionExperimentTreatmentLocalizations").count == 9)
        let sets = fixture.fake.all("appScreenshotSets")
        #expect(sets.count == 18)
        #expect(sets.allSatisfy { $0.relationships["appStoreVersionExperimentTreatmentLocalization"] != nil })
        let expected = ["One": ["01_home.png"], "Two": ["01_list.png", "02_home.png"], "Three": ["01_home.png", "02_list.png"]]
        for (treatment, files) in expected {
            for locale in ["en-US", "da", "de-DE"] {
                for display in [Self.iPhone, Self.iPad] {
                    #expect(try shots(fixture, treatment: treatment, locale: locale, display: display) == files)
                }
            }
        }
        #expect(uploads(fixture) == 3 * 2 * (1 + 2 + 2))
        #expect(fixture.fake.writes.filter { $0 == "POST /v1/appStoreVersionExperimentTreatments" }.count == 3)
    }

    @Test func fourTreatmentsAreRefusedBeforeAnythingIsAsked() async throws {
        let treatments = (1...4).map { Treatment("t\($0)", name: "T\($0)", shots: ["home"]) }
        let fixture = try fixture(Self.experiment(treatments: treatments))
        let error = await #expect(throws: Stopped.self) { try await push(fixture) }
        #expect(error?.description.contains("the story experiment has 4 treatments, and App Store Connect takes 3") == true)
        #expect(fixture.fake.writes.isEmpty)
    }

    @Test func treatmentsAppStoreConnectHasAndTheProjectDoesNotListAreLeftAlone() async throws {
        let fixture = try fixture()
        let id = fixture.fake.add("appStoreVersionExperiments", ["name": "Story test", "trafficProportion": 50, "state": "PREPARE_FOR_SUBMISSION"],
                                  relationships: ["app": ("apps", "app")])
        let old = fixture.fake.add("appStoreVersionExperimentTreatments", ["name": "Old"], relationships: ["appStoreVersionExperiment": ("appStoreVersionExperiments", id)])

        try await push(fixture)

        #expect(fixture.fake.resource(old) != nil)
        #expect(fixture.fake.all("appStoreVersionExperimentTreatments").count == 2)
        #expect(fixture.console.output.contains("warning: Story test experiment · Old is in App Store Connect and not in the project"))
    }

    @Test func moreTreatmentsThanAppStoreConnectTakesIsRefusedWithNothingWritten() async throws {
        let fixture = try fixture(Self.experiment(treatments: [
            Treatment("a", name: "A", shots: ["home"]), Treatment("b", name: "B", shots: ["home"]),
        ]))
        let id = fixture.fake.add("appStoreVersionExperiments", ["name": "Story test", "trafficProportion": 50, "state": "PREPARE_FOR_SUBMISSION"],
                                  relationships: ["app": ("apps", "app")])
        for name in ["Old", "Older"] {
            fixture.fake.add("appStoreVersionExperimentTreatments", ["name": name],
                             relationships: ["appStoreVersionExperiment": ("appStoreVersionExperiments", id)])
        }

        let error = await #expect(throws: Stopped.self) { try await push(fixture) }

        #expect(error?.description.contains("also has Old, Older") == true)
        #expect(fixture.fake.writes.isEmpty)
    }

    /// A treatment that leaves a locale undefined shows the control there
    /// while its visitors still count in the test.
    @Test func aNarrowedPushWarnsOfTheLocalesTheTreatmentLeavesToTheControl() async throws {
        let fixture = try fixture()
        try await push(fixture, locales: "da")
        #expect(fixture.console.output.contains("warning: Story test experiment · Story set does not cover en-US"))
        #expect(try shots(fixture, treatment: "Story set", locale: "da", display: Self.iPad) == ["01_list.png", "02_home.png"])

        let second = try fixture.again()
        second.project = fixture.project
        try await push(second, locales: "en")
        #expect(!second.console.output.contains("does not cover"))
        #expect(try shots(fixture, treatment: "Story set", locale: "en-US", display: Self.iPhone) == ["01_list.png", "02_home.png"])
    }

    @Test func aTreatmentMissingOneDeviceIsNotCovered() async throws {
        let fixture = try fixture()
        try await push(fixture)
        let treatment = try resource(fixture, "appStoreVersionExperimentTreatments", "Story set")
        let english = try #require(fixture.fake.all("appStoreVersionExperimentTreatmentLocalizations").first {
            $0.attributes["locale"] as? String == "en-US" && $0.relationships["appStoreVersionExperimentTreatment"]?.id == treatment.id
        })
        let ipad = try #require(fixture.fake.all("appScreenshotSets").first {
            $0.relationships["appStoreVersionExperimentTreatmentLocalization"]?.id == english.id
                && $0.attributes["screenshotDisplayType"] as? String == Self.iPad
        })
        for screenshot in fixture.fake.screenshots(inSet: ipad.id) {
            let session = fixture.session
            try await session.connect().deleteScreenshot(id: screenshot.id)
        }
        fixture.fake.clearWrites()

        try await push(fixture, locales: "da")

        #expect(fixture.console.output.contains("does not cover en-US"))
    }

    @Test func aDryRunWritesNothing() async throws {
        let fixture = try fixture()
        try await push(fixture, options: dryRun)
        #expect(fixture.fake.writes.isEmpty)
        #expect(fixture.console.output.contains("create  Story test experiment"))
        #expect(fixture.console.output.contains("create  Story test experiment · Story set · da"))
        #expect(fixture.console.output.contains("upload  Story test experiment · Story set · da · iPad 13\""))
    }

    @Test func anAppNotOnSaleFailsTheCreationAndSkipsWhatDependsOnIt() async throws {
        let fixture = try fixture()
        fixture.fake.hasLiveIOSVersion = false
        await #expect(throws: ExitCode.self) { try await push(fixture) }
        #expect(fixture.fake.all("appStoreVersionExperiments").isEmpty)
        #expect(fixture.console.output.contains("failed  create Story test experiment: App Store Connect creates an experiment only once the app has a live iOS version"))
        #expect(fixture.console.output.contains("failed  create Story test experiment · Story set: skipped, because creating Story test experiment failed"))
        #expect(fixture.fake.all("appScreenshots").isEmpty)
    }

    @Test func aProjectWithoutExperimentsSaysSo() async throws {
        let fixture = try Fixture(themes: .frames)
        let error = await #expect(throws: Stopped.self) { try await push(fixture) }
        #expect(error?.description == "The project has no experiments (Project.experiments).")
    }

    @Test func aMissingTreatmentCaptionStopsBeforeAnyRequest() async throws {
        let fixture = try fixture()
        try fixture.updateCopy { copy in
            copy.catalog.strings.removeValue(forKey: "treatment.story.screenshot.list.headline")
        }
        let error = await #expect(throws: ProblemsError.self) { try await push(fixture) }
        #expect(error?.description.contains("treatment.story.screenshot.list.headline is missing") == true)
        #expect(fixture.fake.writes.isEmpty)
    }

    /// The theme draws what it is told, and is told the treatment.
    @Test func aThemeIsToldWhichTreatmentEachFrameBelongsTo() async throws {
        let fixture = try fixture()
        let theme = ListRecordingFrames()
        fixture.project.frames = theme
        try await push(fixture)
        #expect(theme.lists.count == 8)
        #expect(Set(theme.lists) == [.treatment("story")])
        #expect(theme.positions == [0, 1])
    }

    /// The store's own push frames the store's lists alone.
    @Test func aScreenshotsPushFramesNoTreatment() async throws {
        let fixture = try fixture()
        try await Commands.pushScreenshots(fixture.session, platforms: "", locales: "", options: dryRun)
        // Two locales: iPhone and iPad two shots each, the Mac one.
        #expect(try fixture.files(in: fixture.cache.framed).count == 10)
    }

    @Test func exportKeepsTreatmentsApartFromTheStore() async throws {
        let fixture = try fixture()
        let destination = fixture.root.appending(path: "export")
        try await Commands.export(fixture.session, to: destination.path)
        let files = try FileManager.default.subpathsOfDirectory(atPath: destination.path).filter { $0.hasPrefix("ios/en/") && $0.contains(".") }.sorted()
        #expect(files == ["ios/en/01_home.png", "ios/en/02_list.png", "ios/en/treatment-story/01_list.png", "ios/en/treatment-story/02_home.png"])
    }

    @Test func reviewShowsEachTreatmentWithItsCaptions() async throws {
        let fixture = try fixture()
        let state = try await Review(session: fixture.session).state()
        let section = try #require(state.sections.first { $0.id == "treatment-story" })
        #expect(section.group == "Experiments")
        #expect(section.title == "Story test · Story set")
        #expect(section.fields.isEmpty)
        #expect(section.strips.map(\.id) == ["treatment-story-ios", "treatment-story-ipad"])
        #expect(section.strips[0].captions.map { $0[1] } == ["treatment.story.screenshot.list.headline", "screenshot.home.headline"])
        let placed = Set(state.sections.flatMap { $0.fields + $0.strips.flatMap { $0.captions.flatMap { $0 } } })
        #expect(Set(state.fields.map(\.key)).subtracting(placed).isEmpty)
    }
}

/// Records the list each frame it draws belongs to.
final class ListRecordingFrames: FrameTheme, @unchecked Sendable {
    private let lock = NSLock()
    private var drawn: [FramedShot] = []

    var lists: [ShotList] { lock.withLock { drawn.map(\.list) } }
    var positions: Set<Int> { lock.withLock { Set(drawn.map(\.position)) } }

    func render(_ shot: FramedShot, on canvas: Canvas) throws {
        lock.withLock { drawn.append(shot) }
        canvas.context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        canvas.context.fill(canvas.bounds)
    }
}
