import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sending a request again when App Store Connect or its object storage is
/// busy. After 429, which means nothing was done, any request is sent again;
/// after a 5xx only one whose method can be repeated, since a create may
/// have gone through. A request whose body can be read only once is sent
/// once.
public struct Retry: Sendable {
    /// Sends of one request, the first included.
    public var attempts: Int
    let sleep: @Sendable (Duration) async throws -> Void

    public init(attempts: Int = 6) {
        self.init(attempts: attempts) { try await Task.sleep(for: $0) }
    }

    init(attempts: Int, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.attempts = attempts
        self.sleep = sleep
    }

    /// The longest wait between two sends, whatever `Retry-After` asks.
    static let longestWait: Duration = .seconds(120)

    static let repeatable: Set<HTTPRequest.Method> = [.get, .head, .put, .patch, .delete]

    func send(
        _ request: HTTPRequest, body: HTTPBody?,
        _ attempt: @Sendable (HTTPRequest, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let limit = body?.iterationBehavior == .single ? 1 : attempts
        var sent = 1
        while true {
            let (response, responseBody) = try await attempt(request, body)
            guard sent < limit, let wait = wait(after: response, method: request.method, sent: sent) else {
                return (response, responseBody)
            }
            sent += 1
            try await sleep(wait)
        }
    }

    /// How long to wait before sending again, or nil to keep the response:
    /// what `Retry-After` asks, or else 2, 4, 8, 16 and 32 seconds.
    func wait(after response: HTTPResponse, method: HTTPRequest.Method, sent: Int) -> Duration? {
        let code = response.status.code
        guard code == 429 || ((500...599).contains(code) && Self.repeatable.contains(method)) else { return nil }
        if let asked = response.headerFields[.retryAfter].flatMap(Int.init) {
            return min(.seconds(asked), Self.longestWait)
        }
        return min(.seconds(1 << min(sent, 6)), Self.longestWait)
    }
}

struct RetryMiddleware: ClientMiddleware {
    let retry: Retry

    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await retry.send(request, body: body) { request, body in try await next(request, body, baseURL) }
    }
}
