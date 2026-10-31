import CoreGraphics
import Foundation
import Testing
@testable import ProductPageKit
import ProductPageKitRunner

/// `productpage screenshots edit`: the theme's editor, served over the
/// studio that reads frames as the framer does.
@Suite struct EditorTests {
    func respond(_ fixture: Fixture, _ path: String) async throws -> HTTPServer.Response {
        await Commands.respond(to: HTTPServer.Request(method: "GET", path: path, headers: [:], body: Data()),
                               with: SampleEditor(), studio: try Studio(session: fixture.session))
    }

    func body(_ response: HTTPServer.Response) -> String {
        guard case .data(let data) = response.body else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func servesTheEditorsPage() async throws {
        let fixture = try Fixture(themes: .frames)
        let page = try await respond(fixture, "/")
        #expect(page.status == 200 && page.contentType == "text/html; charset=utf-8")
        #expect(body(page) == "<h1>Layouts</h1>")
    }

    /// The studio hands the editor a frame's caption and place in its list,
    /// read again once the catalog changes.
    @Test func theStudioReadsCaptionsAsTheFramerDoes() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        let studio = try Studio(session: fixture.session)
        let request = HTTPServer.Request(method: "GET", path: "/caption?shot=list", headers: [:], body: Data())
        let first = await Commands.respond(to: request, with: SampleEditor(), studio: studio)
        let english = try #require(try fixture.copy.caption(.screenshot("list"), locale: fixture.en)).caption.headline
        #expect(first.status == 200)
        #expect(body(first) == #"{"headline":"\#(english)","position":"1"}"#)

        try await Task.sleep(for: .milliseconds(20))
        try fixture.updateCopy { $0.set("Every list", field: .caption(.screenshot("list"), .headline), locale: fixture.en) }
        let second = await Commands.respond(to: request, with: SampleEditor(), studio: studio)
        #expect(body(second) == #"{"headline":"Every list","position":"1"}"#)
    }

    /// A capture is served from the cache, never kept by the browser, since
    /// it is taken again under the same name.
    @Test func servesCapturesUncached() async throws {
        let fixture = try Fixture(themes: .frames)
        try fixture.writeCaptures()
        let capture = try await respond(fixture, "/capture?shot=home")
        #expect(capture.status == 200 && capture.headers["Cache-Control"] == "no-store")
        let url = fixture.cache.capture(fixture.project.platforms[0], fixture.en, "home")
        guard case .file(let served, _, let length) = capture.body else { Issue.record("not a file"); return }
        let size = try Data(contentsOf: url).count
        #expect(served == url && length == size)
    }

    @Test func aFailedRequestSaysWhy() async throws {
        let fixture = try Fixture(themes: .frames)
        let missing = try await respond(fixture, "/capture?shot=home")
        #expect(missing.status == 400 && body(missing).contains("no iPhone 6.9\\\" capture of home in en"))
        let unknown = try await respond(fixture, "/nothing")
        #expect(unknown.status == 400 && body(unknown).contains("no such request"))
    }

    @Test func aThemeWithoutAnEditorStops() async throws {
        let fixture = try Fixture()
        let error = await #expect(throws: Stopped.self) { try await Commands.editFrames(fixture.session, open: false) }
        #expect(error?.description == "The project's frame theme has no editor.")
    }
}
