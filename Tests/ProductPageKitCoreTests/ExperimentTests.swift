import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKitCore

/// Experiments as the configuration sees them: what a treatment is framed
/// from and captioned with, where its copy lives, and what the checks refuse.
@Suite struct ExperimentTests {
    func configured() -> Project {
        var example = project()
        example.platforms = [.iPhone(shots: ["server", "free"]), .iPad(shots: ["server", "free"]), .mac(window: CGSize(width: 1440, height: 900), shots: ["free"])]
        example.frames = PlainFrames()
        example.experiments = [
            Experiment("story", name: "Story set", trafficProportion: 50, treatments: [
                Treatment("story-a", name: "Story A", shots: ["free", "server"], storeCaptions: ["free"]),
                Treatment("story-b", name: "Story B", shots: ["server"]),
            ]),
        ]
        return example
    }

    @Test func aTreatmentCaptionsItsShotsUnlessItTakesTheStores() {
        let treatment = Treatment("story-a", name: "Story A", shots: ["server", "free"], storeCaptions: ["free"])
        #expect(treatment.list == .treatment("story-a"))
        #expect(treatment.captionSubject("server") == .treatmentScreenshot("story-a", "server"))
        #expect(treatment.captionSubject("free") == .screenshot("free"))
        #expect(Field.caption(.treatmentScreenshot("story-a", "server"), .headline).key == "treatment.story-a.screenshot.server.headline")
        #expect(treatment.fileName(for: "free") == "02_free")
    }

    /// Every treatment is framed on iPhone and iPad, and only there: App
    /// Store Connect has no treatment for a Mac or an Apple TV.
    @Test func eachTreatmentIsFramedOnIPhoneAndIPad() {
        let subjects = configured().frameSubjects.filter { $0.list != .store }
        #expect(subjects.map(\.list).allSatisfy { $0 == .treatment("story-a") || $0 == .treatment("story-b") })
        #expect(subjects.filter { $0.list == .treatment("story-a") }
            == [FrameSubject("free", on: .iPhone, list: .treatment("story-a")), FrameSubject("server", on: .iPhone, list: .treatment("story-a")),
                FrameSubject("free", on: .iPad, list: .treatment("story-a")), FrameSubject("server", on: .iPad, list: .treatment("story-a"))])
        #expect(subjects.count == 6)
        var iPhoneOnly = configured()
        iPhoneOnly.platforms = [.iPhone(shots: ["server", "free"])]
        #expect(iPhoneOnly.alternatePlatforms == [.iPhone])
        #expect(iPhoneOnly.frameSubjects.filter { $0.list == .treatment("story-b") }.map(\.platform) == [.iPhone])
    }

    @Test func aThemeIsToldWhichTreatmentItFrames() {
        let subject = FrameSubject("server", on: .iPad, list: .treatment("story-b"))
        #expect("\(FrameSubject("server", on: .iPad, list: .customPage("pro")))" == "the iPad 13\" server screenshot of the pro page")
        #expect("\(FrameSubject("server", on: .iPad))" == "the iPad 13\" server screenshot")
        #expect("\(subject)" == "the iPad 13\" server screenshot of the story-b treatment")
        #expect(FramedShot(shot: "server", list: .treatment("story-b"), position: 0, count: 1, platform: .iPad,
                           locale: StoreLocale("en", store: "en-US"), caption: Caption(headline: "x"), images: [:]).subject == subject)
        #expect(ShotList.treatment("story-b").folder == "treatment-story-b")
        #expect(ShotList.store.folder == nil)
    }

    @Test func treatmentCopyIsInTheCatalog() {
        var example = configured()
        let copy = StoreCopy(project: example, catalog: StringCatalog(sourceLanguage: "en"))
        let keys = copy.fields.map(\.key)
        #expect(keys.contains("treatment.story-a.screenshot.server.headline"))
        #expect(keys.contains("treatment.story-b.screenshot.server.kicker"))
        #expect(!keys.contains("treatment.story-a.screenshot.free.headline"))
        #expect(copy.problems().map(\.message).contains("treatment.story-b.screenshot.server.headline is missing"))
        example.frames = nil
        #expect(!StoreCopy(project: example, catalog: StringCatalog(sourceLanguage: "en")).fields.map(\.key).contains { $0.hasPrefix("treatment.") })
    }

    @Test func aValidExperimentHasNoProblems() {
        #expect(configured().problems().isEmpty)
    }

    @Test func theChecksRefuseWhatAppStoreConnectWould() {
        var example = configured()
        example.experiments = [
            Experiment("story", name: "Story set", trafficProportion: 0, treatments: []),
            Experiment("story", name: "Story set", trafficProportion: 101, treatments: [
                Treatment("a", name: "Same", shots: ["server"]),
                Treatment("b", name: "Same", shots: ["server", "server"], storeCaptions: ["library", "free"]),
                Treatment("a", name: "Other", shots: []),
                Treatment("d", name: "Fourth", shots: ["server"]),
            ]),
            Experiment("bad key", name: "", trafficProportion: 50, treatments: [Treatment("x_y", name: "", shots: ["server"])]),
        ]
        #expect(example.problems() == [
            "the a treatment has no shots",
            "the a treatment is listed twice",
            "the b treatment gives free the store's caption, and does not list it",
            "the b treatment gives library the store's caption, and does not list it",
            "the b treatment lists server twice",
            "the bad key experiment has no name",
            "the bad key experiment's key must be letters, digits and hyphens",
            "the story experiment has 4 treatments, and App Store Connect takes 3",
            "the story experiment has no treatments",
            "the story experiment has two treatments named Same",
            "the story experiment is listed twice",
            "the story experiment shows treatments to 0 percent of visitors, and the share runs from 1 to 100",
            "the story experiment shows treatments to 101 percent of visitors, and the share runs from 1 to 100",
            "the x_y treatment has no name",
            "the x_y treatment's key must be letters, digits and hyphens",
            "two experiments are named Story set",
        ])
    }

    /// A treatment's store caption must be one the store has.
    @Test func aStoreCaptionIsOneTheStoreHas() {
        var example = configured()
        example.experiments = [Experiment("story", name: "Story set", trafficProportion: 50, treatments: [
            Treatment("a", name: "A", shots: ["server", "demo"], storeCaptions: ["demo"]),
        ])]
        #expect(example.problems() == ["the a treatment gives demo the store's caption, and no platform's list has demo"])
    }

    @Test func anExperimentNeedsAnIPhoneOrIPad() {
        var example = configured()
        example.platforms = [.mac(window: CGSize(width: 1440, height: 900), shots: ["free"])]
        #expect(example.problems() == ["the story experiment shows screenshots on iPhone and iPad, and the project configures neither"])
    }

    @Test func aTreatmentIsCapturedLikeAPageIs() {
        var example = configured()
        example.experiments = [Experiment("story", name: "Story set", trafficProportion: 50, treatments: [
            Treatment("a", name: "A", shots: ["server", "free"]),
        ])]
        #expect(example.captures(on: .iPhone) == ["server", "free"])
        #expect(example.captures(on: .iPad) == ["server", "free"])
    }
}
