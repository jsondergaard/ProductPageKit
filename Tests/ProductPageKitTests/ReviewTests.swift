import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKit
@testable import ProductPageKitCore
import ProductPageKitRunner

/// The review page's server for a fixture, over real HTTP on the loopback
/// interface.
struct ReviewServer {
    let fixture: Fixture
    let server: HTTPServer
    let base: URL

    init(_ fixture: Fixture) async throws {
        self.fixture = fixture
        let review = Review(session: fixture.session)
        server = try HTTPServer { request in await review.handle(request) }
        base = URL(string: "http://127.0.0.1:\(try await server.start())")!
    }

    func request(_ method: String, _ path: String, body: [String: String]? = nil,
                 headers: [String: String] = [:]) async throws -> (Int, Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http)
    }

    func state() async throws -> ReviewState {
        try JSONDecoder().decode(ReviewState.self, from: try await request("GET", "/api/state").1)
    }
}

/// The copy on the review page.
@Suite struct ReviewTests {
    let review: ReviewServer
    var fixture: Fixture { review.fixture }

    init() async throws {
        review = try await ReviewServer(Fixture())
    }

    func request(_ method: String, _ path: String, body: [String: String]? = nil) async throws -> (Int, Data) {
        let (status, data, _) = try await review.request(method, path, body: body)
        return (status, data)
    }

    func state(_ data: Data) throws -> ReviewState { try JSONDecoder().decode(ReviewState.self, from: data) }

    @Test func servesThePage() async throws {
        let (status, data) = try await request("GET", "/")
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("<title>Product page review</title>"))
        review.server.stop()
    }

    @Test func describesTheCopy() async throws {
        let (status, data) = try await request("GET", "/api/state")
        #expect(status == 200)
        let state = try state(data)
        #expect(state.app == "Example")
        #expect(state.sourceLanguage == "en")
        #expect(state.locales.map(\.store) == ["en-US", "da"])
        #expect(state.fields.map(\.key) == ["name", "subtitle", "keywords", "promotionalText", "description",
                                            "whatsNew.1.2", "reviewNotes", "productReviewNote"])
        #expect(state.values["name"]?["da"] == ReviewState.Unit(value: "Eksempel", state: "translated"))
        #expect(state.committed.isEmpty)
        #expect(state.problems.isEmpty)
        review.server.stop()
    }

    @Test func anEditSavesToTheCatalogAndChangesTheRevision() async throws {
        let before = try state(try await request("GET", "/api/state").1)
        let (status, data) = try await request("PUT", "/api/value", body: ["key": "name", "language": "en", "value": "Example Pro"])
        #expect(status == 200)
        let after = try state(data)
        #expect(after.values["name"]?["en"]?.value == "Example Pro")
        #expect(after.values["name"]?["da"]?.state == "needs_review")
        #expect(after.revision != before.revision)
        #expect(try fixture.copy.value(.name, locale: fixture.en) == "Example Pro")
        review.server.stop()
    }

    @Test func approvingMarksATranslationReviewed() async throws {
        try fixture.updateCopy { $0.catalog.set("Eksempel Pro", for: "name", language: "da", state: .needsReview) }
        let (status, data) = try await request("POST", "/api/approve", body: ["key": "name", "language": "da"])
        #expect(status == 200)
        #expect(try state(data).values["name"]?["da"]?.state == "translated")
        #expect(try fixture.copy.value(.name, locale: fixture.da) == "Eksempel Pro")
        review.server.stop()
    }

    @Test func refusesKeysThatAreNotCopy() async throws {
        let (status, data) = try await request("PUT", "/api/value", body: ["key": "nickname", "language": "en", "value": "x"])
        #expect(status == 400)
        #expect(String(decoding: data, as: UTF8.self).contains("nickname is not App Store copy"))
        review.server.stop()
    }

    @Test func comparesWithAppStoreConnect() async throws {
        try await Commands.pushMetadata(fixture.session, locales: "", platforms: "ios", options: apply)
        try fixture.updateCopy { $0.set("Example Pro", field: .name, locale: fixture.en) }
        let (status, data) = try await request("GET", "/api/live")
        #expect(status == 200)
        let live = try JSONDecoder().decode([String: [String: String]].self, from: data)
        #expect(live["name"]?["en"] == "Example")
        #expect(live["whatsNew.1.2"]?["da"] == "Hurtigere.")
        review.server.stop()
    }
}

/// The screenshots and videos on the review page.
@Suite struct ReviewMediaTests {
    @Test func framesTheScreenshotsAndServesThem() async throws {
        let review = try await ReviewServer(Fixture(themes: .frames))
        try review.fixture.writeCaptures()
        let state = try await review.state()
        #expect(state.mediaProblems.isEmpty)
        #expect(state.platforms.map(\.id) == ["ios", "macos"])
        #expect(state.platforms[0].captions == ["screenshot.home", "screenshot.list"])
        #expect(state.screenshots.filter { $0.platform == "ios" && $0.locale == "da" }.map(\.position) == [0, 1])
        let (status, data, response) = try await review.request("GET", state.screenshots[0].url)
        #expect(status == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "max-age=31536000, immutable")
        #expect(try CGImage.read(data, from: URL(filePath: "/")).size == CGSize(width: 1320, height: 2868))
        review.server.stop()
    }

    /// An edited caption shows at once, in a frame drawn for it. Its
    /// translation now needs review, so the Danish frame shows the English.
    @Test func aCaptionEditRedrawsItsFrames() async throws {
        let review = try await ReviewServer(Fixture(themes: .frames))
        try review.fixture.writeCaptures()
        let before = try await review.state()
        let (status, data, _) = try await review.request("PUT", "/api/value",
                                                          body: ["key": "screenshot.list.headline", "language": "en", "value": "All of it"])
        #expect(status == 200)
        let after = try JSONDecoder().decode(ReviewState.self, from: data)
        let changed = zip(before.screenshots, after.screenshots).filter { $0.url != $1.url }.map { "\($1.platform) \($1.locale) \($1.position)" }
        #expect(changed == ["ios en 1", "ios da 1"], "\(changed)")
        #expect(after.revision != before.revision)
        review.server.stop()
    }

    @Test func playsVideosInRangesAndMarksThemOutOfDate() async throws {
        let review = try await ReviewServer(Fixture(themes: .videos))
        try review.fixture.writeCaptures()
        #expect(try await review.state().videos.map(\.url) == [nil, nil])
        try await Commands.renderVideos(review.fixture.session, locales: [review.fixture.en])
        let state = try await review.state()
        let video = try #require(state.videos.first { $0.locale == "en" })
        #expect(video.current)
        #expect(video.caption == "video.header")
        #expect(state.videos.first { $0.locale == "da" }?.url == nil)

        let (status, data, response) = try await review.request("GET", try #require(video.url), headers: ["Range": "bytes=0-99"])
        #expect(status == 206)
        #expect(data.count == 100)
        #expect(response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-99/") == true)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/mp4")

        try review.fixture.updateCopy { $0.set("New", field: .caption(.video(.header), .headline), locale: review.fixture.en) }
        #expect(try await review.state().videos.first { $0.locale == "en" }?.current == false)
        review.server.stop()
    }

    @Test func servesOnlyCacheFilesAndTheIcon() async throws {
        let fixture = try Fixture()
        fixture.project.icon = "icon.png"
        try fixture.write(ImageFormat.png.encode(Canvas(size: CGSize(width: 8, height: 8)).image()), to: "icon.png")
        let review = try await ReviewServer(fixture)
        #expect(try await review.state().icon)
        #expect(try await review.request("GET", "/media/icon").0 == 200)
        #expect(try await review.request("GET", "/media/..%2F..%2Fcatalogue.json").0 == 404)
        #expect(try await review.request("GET", "/media/0123456789abcdef0123456789abcdef.png").0 == 404)
        review.server.stop()
    }

    @Test func missingCapturesAreSaidNotFailed() async throws {
        let review = try await ReviewServer(Fixture(themes: .frames))
        let state = try await review.state()
        #expect(state.screenshots.isEmpty)
        #expect(state.mediaProblems.first?.contains("no iPhone 6.9\" capture of home in en") == true)
        review.server.stop()
    }
}
