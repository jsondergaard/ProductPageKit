import CoreGraphics
import Foundation
import ProductPageKitCore
import ProductPageKitRunner
import Synchronization

/// What a theme's editor draws from, read as the framer reads it. Each
/// image is read once for each version of its file, and the copy once for
/// each version of the catalog, so an editor can ask for a frame on every
/// change and still see a new capture or caption.
final class Studio: FrameStudio {
    let session: Session
    private let framer: Framer
    private let images = Mutex<[URL: (modified: Date, image: CGImage, highlights: [CGRect])]>([:])
    private let copy = Mutex<(modified: Date, copy: StoreCopy)?>(nil)

    init(session: Session) throws {
        self.session = session
        let console = session.console
        framer = Framer(copy: try session.copy(), cache: session.cache) { console.print($0) }
    }

    var project: Project { session.project }

    func url(of source: FrameSource, locale: StoreLocale) async throws -> URL {
        try await place(of: source, locale: locale).url
    }

    func shot(_ subject: FrameSubject, locale: StoreLocale, sources: [FrameSource]) async throws -> FramedShot {
        guard let listing = project.listing(subject.list, on: subject.platform),
              let position = listing.shots.firstIndex(of: subject.shot) else {
            throw Stopped(description: "The project does not frame \(subject).")
        }
        var captions = CaptionReader(try currentCopy())
        let caption = try captions.caption(listing.captionSubject(subject.shot), locale: locale).get()
        var images: [FrameSource: CGImage] = [:]
        var highlights: [FrameSource: [CGRect]] = [:]
        var files: [String: URL] = [:]
        for source in sources {
            let place = try await place(of: source, locale: locale)
            if case .file(let name) = source.content {
                files[name] = place.url
            } else if let (image, marks) = try read(place) {
                images[source] = image
                highlights[source] = marks
            }
        }
        return FramedShot(shot: subject.shot, list: subject.list, position: position, count: listing.shots.count,
                          platform: subject.platform, locale: locale, caption: caption, images: images, highlights: highlights,
                          files: files)
    }

    private func place(of source: FrameSource, locale: StoreLocale) async throws -> Framer.Found {
        var files: [String: URL] = [:]
        if case .file(let name) = source.content {
            files[name] = try await framer.files.prepare().appending(path: name)
        }
        return try framer.find(source, locale: locale, files: files).mapError { Stopped(description: "\($0.description) in \(locale.code)") }.get()
    }

    private func read(_ place: Framer.Found) throws -> (image: CGImage, highlights: [CGRect])? {
        let modified = try Self.modified(place.url)
        if let cached = images.withLock({ $0[place.url] }), cached.modified == modified { return (cached.image, cached.highlights) }
        guard let read = try place.read() else { return nil }
        images.withLock { $0[place.url] = (modified, read.image, read.highlights) }
        return read
    }

    private func currentCopy() throws -> StoreCopy {
        let modified = try Self.modified(StoreCopy.url(project, root: session.root))
        if let cached = copy.withLock({ $0 }), cached.modified == modified { return cached.copy }
        let read = try session.copy()
        copy.withLock { $0 = (modified, read) }
        return read
    }

    private static func modified(_ url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
    }
}

extension Commands {
    /// Serves the theme's layout editor on 127.0.0.1 and opens it in the
    /// browser. Runs until stopped.
    static func editFrames(_ session: Session, open: Bool) async throws {
        try session.checkProject()
        guard let editor = session.project.frames?.editor else {
            throw Stopped(description: "The project's frame theme has no editor.")
        }
        let studio = try Studio(session: session)
        let server = try HTTPServer { request in await respond(to: request, with: editor, studio: studio) }
        let port = try await server.start()
        let url = "http://127.0.0.1:\(port)/"
        session.console.print("Editing the frames' layouts at \(url)")
        session.console.print("Press Ctrl-C to stop.")
        if open { _ = try? await Shell.run("open '\(url)'", in: session.root) }
        while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
    }

    static func respond(to request: HTTPServer.Request, with editor: any FrameEditor, studio: any FrameStudio) async -> HTTPServer.Response {
        let query = URLComponents(string: request.path)?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" } ?? [:]
        do {
            let response = try await editor.respond(to: EditorRequest(method: request.method, route: request.route, query: query,
                                                                      body: request.body), studio: studio)
            switch response.body {
            case .data(let data):
                return HTTPServer.Response(status: response.status, contentType: response.contentType, body: data)
            case .file(let url):
                // A capture is taken again under the same name.
                var file = try HTTPServer.Response.file(url, contentType: response.contentType, range: nil)
                file.headers = ["Cache-Control": "no-store"]
                return file
            }
        } catch {
            return .error(400, "\(error)")
        }
    }
}
