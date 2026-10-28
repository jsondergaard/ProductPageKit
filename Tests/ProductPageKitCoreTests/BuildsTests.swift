import Testing
@testable import ProductPageKitCore

@Suite struct BuildNumberTests {
    @Test func readsOneToThreeWholeNumbers() {
        #expect(BuildNumber("88")?.components == [88])
        #expect(BuildNumber("88.1")?.components == [88, 1])
        #expect(BuildNumber("1.2.3")?.components == [1, 2, 3])
        for text in ["", "1.2.3.4", "1..2", "88.", "-1", "1a", "١٢", " 1"] {
            #expect(BuildNumber(text) == nil, "\(text)")
        }
    }

    @Test func comparesNumberByNumberWithMissingOnesAsZero() throws {
        func number(_ text: String) throws -> BuildNumber { try #require(BuildNumber(text)) }
        #expect(try number("9.9") < number("88"))
        #expect(try number("88") < number("88.1"))
        #expect(try number("88.2") < number("88.10"))
        #expect(try number("88") == number("88.0.0"))
        #expect(try Set([number("88"), number("88.0")]).count == 1)
    }

    @Test func nextIsOneMoreThanTheHighestWhole() throws {
        let uploaded = try ["87", "88.2", "9"].map { try #require(BuildNumber($0)) }
        #expect(BuildNumbering.next.number(after: uploaded).description == "89")
        #expect(BuildNumbering.next.number(after: []).description == "1")
    }

    @Test func minorFollowsTheHighestAndStaysBelowItsNextWhole() throws {
        func after(_ texts: [String]) throws -> String {
            BuildNumbering.minor.number(after: try texts.map { try #require(BuildNumber($0)) }).description
        }
        #expect(try after(["87", "88"]) == "88.1")
        #expect(try after(["88", "88.1"]) == "88.2")
        #expect(try after(["88.4", "89"]) == "89.1")
        #expect(try after(["88.1.5"]) == "88.2")
        #expect(try after([]) == "0.1")
    }
}

@Suite struct BuildsConfigurationTests {
    @Test func platformsDefaultToTheProductPages() {
        var example = project()
        example.builds = Builds()
        #expect(example.buildPlatforms == [.iOS, .macOS])
        example.builds = Builds(platforms: [.tvOS])
        #expect(example.buildPlatforms == [.tvOS])
    }

    @Test func buildsNeedAnXcodeProjectAndPlatformsOnce() {
        var example = project()
        example.builds = Builds(platforms: [.iOS, .iOS])
        #expect(example.problems() == ["builds are archived from the Xcode project, and none is configured", "builds list iOS twice"])
        example.xcode = .project("App.xcodeproj", scheme: "App")
        example.builds = Builds(platforms: [])
        #expect(example.problems() == ["builds name no platforms"])
    }
}
