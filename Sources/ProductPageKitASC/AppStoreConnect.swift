import Foundation
import HTTPTypes
public import OpenAPIRuntime
import OpenAPIURLSession

/// The App Store Connect API, for one API key.
///
/// Every request is signed with a short-lived token. A response of 400 or
/// more throws `ASCError` with App Store Connect's own explanation. Asset
/// uploads go through the same transport as API calls, to the URLs App Store
/// Connect hands out for them.
public struct AppStoreConnect: Sendable {
    let client: Client
    let transport: any ClientTransport

    public init(credentials: Credentials) {
        self.init(credentials: credentials, transport: URLSessionTransport())
    }

    public init(credentials: Credentials, transport: any ClientTransport) {
        self.transport = transport
        client = Client(
            serverURL: URL(string: "https://api.appstoreconnect.apple.com")!,
            configuration: Configuration(dateTranscoder: AppStoreConnectDates()),
            transport: transport,
            middlewares: [AuthenticationMiddleware(signer: TokenSigner(credentials: credentials)), ErrorMiddleware()]
        )
    }

    /// Runs a generated call, surfacing the `ASCError` a middleware threw
    /// rather than the client's wrapper around it.
    func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ClientError {
            throw (error.underlyingError as? ASCError) ?? error
        }
    }

    /// Every page of a collection. `page` fetches one page from a cursor, nil
    /// for the first, and returns its items and its `links.next`.
    func all<Item>(_ page: (String?) async throws -> (items: [Item], next: String?)) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        repeat {
            let result = try await call { try await page(cursor) }
            items += result.items
            cursor = result.next.flatMap(Self.cursor(fromNext:))
        } while cursor != nil
        return items
    }

    /// A response's `data`, which App Store Connect always sends after a
    /// create or update even where the schema allows it to be absent.
    func present<T>(_ data: T?, _ operation: String) throws -> T {
        guard let data else { throw MissingData(operation: operation) }
        return data
    }

    /// The `cursor` query item of a `links.next` URL.
    static func cursor(fromNext next: String) -> String? {
        URLComponents(string: next)?.queryItems?.first { $0.name == "cursor" }?.value
    }
}

public struct MissingData: Error, CustomStringConvertible {
    public let operation: String
    public var description: String { "App Store Connect answered \(operation) without the resource." }
}

/// An error response from App Store Connect.
public struct ASCError: Error, CustomStringConvertible, Sendable {
    public struct Item: Decodable, Sendable {
        public let code: String?
        public let title: String?
        public let detail: String?
    }

    public let method: String
    public let path: String
    public let status: Int
    public let errors: [Item]
    public let body: String

    init(method: String, path: String, status: Int, body: Data) {
        self.method = method
        self.path = path
        self.status = status
        struct Document: Decodable { let errors: [Item] }
        errors = (try? JSONDecoder().decode(Document.self, from: body))?.errors ?? []
        self.body = String(decoding: body.prefix(800), as: UTF8.self)
    }

    /// A create that collided with a record App Store Connect already has.
    public var isDuplicate: Bool { status == 409 && hasCode(containing: "DUPLICATE") }

    /// Whether any error's code contains `fragment`: `STATE_ERROR.PPO_CREATE_ONLY_...`.
    func hasCode(containing fragment: String) -> Bool {
        errors.contains { ($0.code ?? "").contains(fragment) }
    }

    public var isNotFound: Bool { status == 404 }

    public var description: String {
        let detail = errors.isEmpty
            ? body
            : errors.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: ": ") }.joined(separator: "; ")
        return "\(method) \(path) -> \(status): \(detail)"
    }
}

struct AuthenticationMiddleware: ClientMiddleware {
    let signer: TokenSigner

    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(try await signer.token())"
        return try await next(request, body, baseURL)
    }
}

struct ErrorMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status.code >= 400 else { return (response, responseBody) }
        var data = Data()
        if let responseBody { data = try await Data(collecting: responseBody, upTo: 1 << 20) }
        throw ASCError(method: request.method.rawValue, path: request.path ?? "", status: response.status.code, body: data)
    }
}

/// App Store Connect writes some dates with fractional seconds
/// (`2026-09-30T17:07:20.123-07:00`) and some without.
struct AppStoreConnectDates: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601)
    }

    func decode(_ string: String) throws -> Date {
        for style in [Date.ISO8601FormatStyle(), Date.ISO8601FormatStyle(includingFractionalSeconds: true)] {
            if let date = try? style.parse(string) { return date }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(string) is not an ISO 8601 date"))
    }
}
