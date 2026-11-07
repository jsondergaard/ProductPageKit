public import Foundation
public import HTTPTypes

/// Sending a request again when a store's API or its object storage is busy.
/// After 429, which means nothing was done, any request is sent again; after
/// a 5xx, or no answer in time, only one whose method can be repeated, since
/// a create may have gone through. A request whose body can be read only
/// once is sent once.
public struct Retry: Sendable {
    /// Sends of one request, the first included.
    public var attempts: Int
    let sleep: @Sendable (Duration) async throws -> Void

    public init(attempts: Int = 6) {
        self.init(attempts: attempts) { try await Task.sleep(for: $0) }
    }

    /// - Parameter sleep: waits out a pause between sends; a test records it.
    public init(attempts: Int, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.attempts = attempts
        self.sleep = sleep
    }

    /// The longest wait between two sends, whatever `Retry-After` asks.
    static let longestWait: Duration = .seconds(120)

    static let repeatable: Set<HTTPRequest.Method> = [.get, .head, .put, .patch, .delete]

    /// Sends `method`'s request by `attempt` until it is answered with
    /// something other than busy, or the attempts run out.
    /// - Parameter once: the request's body can be read only once.
    public func send<Body>(_ method: HTTPRequest.Method, once: Bool = false,
                           _ attempt: () async throws -> (HTTPResponse, Body)) async throws -> (HTTPResponse, Body) {
        let limit = once ? 1 : attempts
        var sent = 1
        while true {
            let wait: Duration
            do {
                let (response, body) = try await attempt()
                guard sent < limit, let busy = self.wait(after: response, method: method, sent: sent) else {
                    return (response, body)
                }
                wait = busy
            } catch let error as URLError where sent < limit && Self.repeatable.contains(method)
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
