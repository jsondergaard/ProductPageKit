public import Foundation

/// A theme's layout editor: a page in the browser that
/// `productpage screenshots edit` serves on 127.0.0.1, and the requests it
/// makes. The theme draws what the page shows, so a layout is seen as the
/// frame will be before it is saved.
public protocol FrameEditor: Sendable {
    /// Answers each request from the browser, the page itself at `/`. A
    /// thrown error is answered with status 400 and its description.
    func respond(to request: EditorRequest, studio: any FrameStudio) async throws -> EditorResponse
}

/// What an editor draws from: the project, and each frame's sources and
/// caption as the framer hands them to the theme.
public protocol FrameStudio: Sendable {
    var project: Project { get }
    /// Where `source` is in `locale`: a capture or component in the cache,
    /// or a file the project prepares.
    func url(of source: FrameSource, locale: StoreLocale) async throws -> URL
    /// `subject` in `locale` as the framer hands it to the theme, but drawn
    /// from `sources` rather than what the theme lists for it, so an editor
    /// can draw a layout that is not saved yet.
    func shot(_ subject: FrameSubject, locale: StoreLocale, sources: [FrameSource]) async throws -> FramedShot
}

public struct EditorRequest: Sendable {
    public let method: String
    /// The path without its query: `/api/layout`.
    public let route: String
    public let query: [String: String]
    public let body: Data

    public init(method: String, route: String, query: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.route = route
        self.query = query
        self.body = body
    }

    /// The body read as JSON.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

public struct EditorResponse: Sendable {
    public enum Body: Sendable, Equatable {
        case data(Data)
        /// A file, read as it is sent.
        case file(URL)
    }

    public let status: Int
    public let contentType: String
    public let body: Body

    public init(status: Int = 200, contentType: String, body: Body) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> EditorResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return EditorResponse(status: status, contentType: "application/json", body: .data(try encoder.encode(value)))
    }

    public static func html(_ page: Data) -> EditorResponse {
        EditorResponse(contentType: "text/html; charset=utf-8", body: .data(page))
    }

    public static func png(_ data: Data) -> EditorResponse {
        EditorResponse(contentType: "image/png", body: .data(data))
    }
}
