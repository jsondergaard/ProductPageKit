public import Foundation
public import HTTPTypes
import HTTPTypesFoundation
public import ProductPageKitHTTP

/// Sends one request and returns the answer, whatever its status: URLSession,
/// or a fake in tests.
public protocol PlayTransport: Sendable {
    func send(_ request: HTTPRequest, body: Data?) async throws -> (HTTPResponse, Data)
}

public struct URLSessionPlayTransport: PlayTransport {
    public init() {}

    public func send(_ request: HTTPRequest, body: Data?) async throws -> (HTTPResponse, Data) {
        let (data, response) = if let body {
            try await URLSession.shared.upload(for: request, from: body)
        } else {
            try await URLSession.shared.data(for: request)
        }
        return (response, data)
    }
}

/// The Google Play Developer Publishing API, for one service account.
///
/// Every read and write goes through an edit: a draft of the app's listing
/// that nothing outside it sees until it is committed. A busy answer is sent
/// again as `retry` allows, and a response of 400 or more throws `PlayError`
/// with Google's own explanation.
public struct GooglePlayAPI: Sendable {
    let transport: any PlayTransport
    let retry: Retry
    let tokens: AccessTokens

    public init(credentials: PlayCredentials, transport: any PlayTransport = URLSessionPlayTransport(), retry: Retry = Retry()) {
        self.transport = transport
        self.retry = retry
        tokens = AccessTokens(credentials: credentials)
    }

    static let host = "androidpublisher.googleapis.com"
    static let scope = "https://www.googleapis.com/auth/androidpublisher"

    /// Opens an edit of `packageName`'s listing.
    public func edit(packageName: String) async throws -> PlayEdit {
        struct Created: Decodable { let id: String }
        let created: Created = try await call(.post, "/androidpublisher/v3/applications/\(packageName)/edits", json: Data("{}".utf8))
        return PlayEdit(api: self, packageName: packageName, id: created.id)
    }

    /// Sends a request to the API with a current token and decodes its
    /// answer, throwing `PlayError` for a status of 400 or more.
    func call<Answer: Decodable>(_ method: HTTPRequest.Method, _ path: String, query: String? = nil, json: Data? = nil,
                                 upload: (data: Data, contentType: String)? = nil) async throws -> Answer {
        let data = try await send(method, path, query: query, json: json, upload: upload)
        do {
            return try JSONDecoder().decode(Answer.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw PlayError(status: 200, method: method.rawValue, path: path,
                            message: "the answer could not be read: \(String(decoding: data, as: UTF8.self))")
        }
    }

    /// Sends a request whose answer has no body worth reading.
    func perform(_ method: HTTPRequest.Method, _ path: String, query: String? = nil) async throws {
        _ = try await send(method, path, query: query, json: nil, upload: nil)
    }

    private func send(_ method: HTTPRequest.Method, _ path: String, query: String?, json: Data?,
                      upload: (data: Data, contentType: String)?) async throws -> Data {
        let token = try await tokens.current(transport: transport, retry: retry)
        var request = HTTPRequest(method: method, scheme: "https", authority: Self.host,
                                  path: path + (query.map { "?\($0)" } ?? ""))
        request.headerFields[.authorization] = "Bearer \(token)"
        let body = upload?.data ?? json
        if let upload {
            request.headerFields[.contentType] = upload.contentType
        } else if json != nil {
            request.headerFields[.contentType] = "application/json"
        }
        let (response, data) = try await retry.send(method) { try await transport.send(request, body: body) }
        guard response.status.code < 400 else {
            throw PlayError(status: response.status.code, method: method.rawValue, path: path, message: PlayError.message(in: data))
        }
        return data
    }
}

/// Access tokens for the service account, each kept until shortly before it
/// expires. Requests that need one while it is being fetched wait for that
/// fetch rather than starting their own.
actor AccessTokens {
    let credentials: PlayCredentials
    private var token: (value: String, expires: Date)?
    private var fetching: Task<(value: String, expires: Date), any Error>?

    init(credentials: PlayCredentials) {
        self.credentials = credentials
    }

    func current(transport: any PlayTransport, retry: Retry, now: Date = Date()) async throws -> String {
        if let token, token.expires.timeIntervalSince(now) > 60 { return token.value }
        let fetch = fetching ?? Task { [credentials] in try await Self.fetch(credentials, transport: transport, retry: retry, now: now) }
        fetching = fetch
        defer { fetching = nil }
        let fetched = try await fetch.value
        token = fetched
        return fetched.value
    }

    private static func fetch(_ credentials: PlayCredentials, transport: any PlayTransport, retry: Retry,
                              now: Date) async throws -> (value: String, expires: Date) {
        let assertion = try assertion(credentials, issuedAt: now)
        var request = HTTPRequest(method: .post, scheme: credentials.tokenURI.scheme, authority: credentials.tokenURI.host(),
                                  path: credentials.tokenURI.path())
        request.headerFields[.contentType] = "application/x-www-form-urlencoded"
        let body = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (response, data) = try await retry.send(.post) { try await transport.send(request, body: body) }
        struct Granted: Decodable {
            let access_token: String
            let expires_in: Int
        }
        guard response.status.code < 400, let granted = try? JSONDecoder().decode(Granted.self, from: data) else {
            throw PlayError(status: response.status.code, method: "POST", path: credentials.tokenURI.absoluteString,
                            message: PlayError.message(in: data))
        }
        return (granted.access_token, now.addingTimeInterval(TimeInterval(granted.expires_in)))
    }

    /// The JWT the account signs to ask for a token: good for an hour, for
    /// the Publishing API's scope.
    static func assertion(_ credentials: PlayCredentials, issuedAt now: Date) throws -> String {
        let issued = Int(now.timeIntervalSince1970)
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let claims: [String: Any] = [
            "iss": credentials.clientEmail, "scope": GooglePlayAPI.scope, "aud": credentials.tokenURI.absoluteString,
            "iat": issued, "exp": issued + 3600,
        ]
        let signed = base64URL(Data(header.utf8)) + "." + base64URL(try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        return signed + "." + base64URL(try credentials.sign(Data(signed.utf8)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A response of 400 or more, with Google's explanation.
public struct PlayError: Error, CustomStringConvertible {
    public let status: Int
    public let method: String
    public let path: String
    public let message: String

    public var description: String { "\(method) \(path) -> \(status): \(message)" }

    /// `error.message` from Google's error body, or the body itself.
    static func message(in data: Data) -> String {
        struct Body: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
            let error_description: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        return body?.error?.message ?? body?.error_description ?? String(decoding: data, as: UTF8.self)
    }
}
