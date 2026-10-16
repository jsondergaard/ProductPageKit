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

    func get<Value: Decodable>(_ path: String) async throws -> Value {
        let (status, data, _) = try await request("GET", path)
        #expect(status == 200, "\(String(decoding: data, as: UTF8.self))")
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func screenshots(_ query: String) async throws -> [Review.Screenshot] {
        try await get("/api/screenshots?\(query)")
    }

    func videos(_ locale: String) async throws -> [Review.Video] {
        try await get("/api/videos?locale=\(locale)")
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
        #expect(state.sections.map(\.id) == ["listing", "search", "whats-new", "app-review", "screenshots"])
        #expect(state.sections[2].fields == ["whatsNew.1.2"])
        #expect(state.sections[3].fields == ["reviewNotes", "productReviewNote"])
        #expect(state.sections[4].strips.map(\.name) == ["iPhone 6.9\"", "Mac"])
        #expect(state.sections[4].strips.allSatisfy { $0.captions.isEmpty })
        review.server.stop()
    }

    /// The copy alone: framing every screenshot would make each edit wait.
    @Test func theStateFramesNothing() async throws {
        try fixture.writeCaptures()
        #expect(try await request("GET", "/api/state").0 == 200)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.framed.path))
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

    @Test func checksNameTheirFieldAndLocale() async throws {
        try fixture.updateCopy {
            $0.set(String(repeating: "x", count: 31), field: .name, locale: fixture.da)
            $0.catalog.strings["whatsNew.1.2"]?.localizations?["da"] = nil
        }
        let problems = try await review.state().problems
        let long = try #require(problems.first { $0.message.hasPrefix("name · da:") })
        #expect(long.key == "name")
        #expect(long.locale == "da")
        let untranslated = try #require(problems.first { $0.message.hasPrefix("whatsNew.1.2:") })
        #expect(untranslated.key == "whatsNew.1.2")
        #expect(untranslated.locale == nil)
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

/// How the page is laid out: every field in a section, each custom page and
/// video in its own.
@Suite struct ReviewSectionTests {
    @Test func everyFieldHasAPlace() async throws {
        let fixture = try Fixture(themes: [.frames, .videos])
        fixture.project.customPages = [CustomPage("pager", name: "Pager", platforms: [.iPhone, .iPad], shots: ["home", "list"],
                                                  storeCaptions: ["list"])]
        let state = try await Review(session: fixture.session).state()
        #expect(state.sections.map(\.id) == ["listing", "search", "whats-new", "app-review", "screenshots", "page-pager",
                                             "video-header"])
        let placed = Set(state.sections.flatMap { $0.fields + $0.strips.flatMap { $0.captions.flatMap { $0 } } })
        #expect(Set(state.fields.map(\.key)).subtracting(placed).isEmpty)
        #expect(placed.subtracting(state.fields.map(\.key)).isEmpty)

        // The page has no iPad platform to show, and reuses the store's caption for the list.
        let page = state.sections[5]
        #expect(page.fields == ["page.pager.promotionalText"])
        #expect(page.strips.map(\.id) == ["page-pager-ios"])
        #expect(page.strips[0].captions.map { $0[1] } == ["page.pager.screenshot.home.headline", "screenshot.list.headline"])
        #expect(state.sections[6].fields == ["video.header.kicker", "video.header.headline", "video.header.subline"])
        #expect(state.sections[6].video == "header")
    }
}

/// The screenshots and videos on the review page, each framed or read when
/// asked for.
@Suite struct ReviewMediaTests {
    @Test func framesAStripInALocaleAndServesIt() async throws {
        let review = try await ReviewServer(Fixture(themes: .frames))
        try review.fixture.writeCaptures()
        let state = try await review.state()
        #expect(state.sections.last?.strips.map(\.id) == ["ios", "macos"])
        #expect(state.sections.last?.strips[0].captions.map { $0[1] } == ["screenshot.home.headline", "screenshot.list.headline"])
        let shots = try await review.screenshots("strip=ios&locale=da")
        #expect(shots.map(\.position) == [0, 1])
        #expect(shots.allSatisfy { $0.locale == "da" && $0.problems.isEmpty })
        let (status, data, response) = try await review.request("GET", try #require(shots[0].url))
        #expect(status == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "max-age=31536000, immutable")
        #expect(try CGImage.read(data, from: URL(filePath: "/")).size == CGSize(width: 1320, height: 2868))
        review.server.stop()
    }

    @Test func framesOnePositionInEveryLocale() async throws {
        let review = try await ReviewServer(Fixture(themes: .frames))
        try review.fixture.writeCaptures()
        let shots = try await review.screenshots("strip=ios&position=1")
        #expect(shots.map(\.locale) == ["en", "da"])
        #expect(shots.allSatisfy { $0.position == 1 && $0.url != nil })
        #expect(try await review.screenshots("strip=ios&locale=en")[1].url == shots[0].url)
        review.server.stop()
    }

    /// An edited caption shows at once, in a frame drawn for it. Its
    /// translation now needs review, so the Danish frame shows the English.
    @Test func aCaptionEditRedrawsItsFrames() async throws {
        let review = try await ReviewServer(Fixture(themes: .frames))
        try review.fixture.writeCaptures()
        let before = try await review.screenshots("strip=ios&locale=en") + (try await review.screenshots("strip=ios&locale=da"))
        let (status, _, _) = try await review.request("PUT", "/api/value",
                                                       body: ["key": "screenshot.list.headline", "language": "en", "value": "All of it"])
        #expect(status == 200)
        let after = try await review.screenshots("strip=ios&locale=en") + (try await review.screenshots("strip=ios&locale=da"))
        let changed = zip(before, after).filter { $0.url != $1.url }.map { "\($1.locale) \($1.position)" }
        #expect(changed == ["en 1", "da 1"], "\(changed)")
        // Framing one strip keeps the other strips' frames.
        let index = CacheIndex<FramedItem>.read(in: review.fixture.cache.framed)
        #expect(Set(index.entries.map(\.item.locale)) == ["en", "da"])
        #expect(try review.fixture.files(in: review.fixture.cache.framed).count == index.entries.count)
        review.server.stop()
    }

    /// What can be framed is, and each other screenshot says what it lacks.
    @Test func missingCapturesAreSaidPerScreenshot() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        try FileManager.default.removeItem(at: fixture.cache.raw(fixture.project.platforms[0], fixture.da).appending(path: "02_list.png"))
        let review = try await ReviewServer(fixture)
        let da = try await review.screenshots("strip=ios&locale=da")
        #expect(da[0].url != nil)
        #expect(da[1].url == nil)
        #expect(da[1].problems == ["no iPhone 6.9\" capture of list"])
        #expect(try await review.screenshots("strip=ios&locale=en").allSatisfy { $0.url != nil })
        review.server.stop()
    }

    @Test func refusesUnknownStripsAndVagueRequests() async throws {
        let review = try await ReviewServer(Fixture(themes: .frames))
        let unknown = try await review.request("GET", "/api/screenshots?strip=tvos&locale=en")
        #expect(unknown.0 == 400)
        #expect(String(decoding: unknown.1, as: UTF8.self).contains("tvos is not a strip of screenshots"))
        #expect(try await review.request("GET", "/api/screenshots?strip=ios").0 == 400)
        #expect(try await review.request("GET", "/api/screenshots?strip=ios&position=2").0 == 400)
        #expect(try await review.request("GET", "/api/screenshots?strip=ios&locale=fr").0 == 400)
        #expect(try await review.request("GET", "/api/videos").0 == 400)
        review.server.stop()
    }

    @Test func playsVideosInRangesAndMarksThemOutOfDate() async throws {
        let review = try await ReviewServer(Fixture(themes: .videos))
        try review.fixture.writeCaptures()
        #expect(try await review.videos("en").map(\.url) == [nil])
        try await Commands.renderVideos(review.fixture.session, locales: [review.fixture.en])
        let video = try #require(try await review.videos("en").first)
        #expect(video.current)
        #expect(video.kind == "header")
        #expect(video.problems.isEmpty)
        #expect(try await review.videos("da")[0].url == nil)

        let (status, data, response) = try await review.request("GET", try #require(video.url), headers: ["Range": "bytes=0-99"])
        #expect(status == 206)
        #expect(data.count == 100)
        #expect(response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-99/") == true)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/mp4")

        try review.fixture.updateCopy { $0.set("New", field: .caption(.video(.header), .headline), locale: review.fixture.en) }
        #expect(try await review.videos("en")[0].current == false)
        review.server.stop()
    }

    @Test func aVideoSaysWhatStopsItRendering() async throws {
        let fixture = try Fixture(themes: .videos)
        try fixture.writeCaptures()
        try FileManager.default.removeItem(at: fixture.cache.raw(fixture.project.platforms[0], fixture.da).appending(path: "02_list.png"))
        let review = try await ReviewServer(fixture)
        #expect(try await review.videos("da").map(\.problems) == [["no iPhone 6.9\" capture of list"]])
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
}
