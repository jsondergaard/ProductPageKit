import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sending a request again when App Store Connect or its object storage is
/// busy. After 429, which means nothing was done, any request is sent again;
/// after a 5xx, or no answer in time, only one whose method can be repeated,
/// since a create may have gone through. A request whose body can be read
/// only once is sent once.
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
            let wait: Duration
            do {
                let (response, responseBody) = try await attempt(request, body)
                guard sent < limit, let busy = self.wait(after: response, method: request.method, sent: sent) else {
                    return (response, responseBody)
                }
                wait = busy
            } catch let error as URLError where sent < limit && Self.repeatable.contains(request.method)
                        && Self.unanswered.contains(error.code) {
                wait = Self.backoff(sent: sent)
            }
            sent += 1
            try await sleep(wait)
        }
    }

    /// Failures where the request may never have arrived, or its answer was
    /// lost on the way back.
    static let unanswered: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
    ]

    /// 2, 4, 8, 16 and 32 seconds.
    static func backoff(sent: Int) -> Duration {
        min(.seconds(1 << min(sent, 6)), longestWait)
    }

    /// How long to wait before sending again, or nil to keep the response:
    /// what `Retry-After` asks, or else 2, 4, 8, 16 and 32 seconds.
    func wait(after response: HTTPResponse, method: HTTPRequest.Method, sent: Int) -> Duration? {
        let code = response.status.code
        guard code == 429 || ((500...599).contains(code) && Self.repeatable.contains(method)) else { return nil }
        if let asked = response.headerFields[.retryAfter].flatMap(Int.init) {
            return min(.seconds(asked), Self.longestWait)
        }
        return Self.backoff(sent: sent)
    }
}

/// A transport that sends again as `retry` allows. It wraps the transport
/// itself rather than sitting among the middlewares, since the client hands
/// those a transport failure already wrapped, its `URLError` out of reach.
struct RetryingTransport: ClientTransport {
    let base: any ClientTransport
    let retry: Retry

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        try await retry.send(request, body: body) { request, body in
            try await base.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
    }
}
