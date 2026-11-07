import Foundation
import HTTPTypes
import OpenAPIRuntime
import ProductPageKitHTTP

/// A transport that sends again as `retry` allows. It wraps the transport
/// itself rather than sitting among the middlewares, since the client hands
/// those a transport failure already wrapped, its `URLError` out of reach.
struct RetryingTransport: ClientTransport {
    let base: any ClientTransport
    let retry: Retry

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        try await retry.send(request.method, once: body?.iterationBehavior == .single) {
            try await base.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
    }
}
