package import Foundation
import Network

extension HTTPServer {
    package struct Request: Sendable {
        package let method: String
        package let path: String
        /// Names lowercased.
        package let headers: [String: String]
        package let body: Data

        package init(method: String, path: String, headers: [String: String], body: Data) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }

        /// The path without its query: `/api/screenshots`.
        package var route: String {
            String(path.prefix { $0 != "?" })
        }

        /// A query parameter's value, decoded, or nil when it is absent.
        package func query(_ name: String) -> String? {
            URLComponents(string: path)?.queryItems?.first { $0.name == name }?.value
        }
    }

    package struct Response: Sendable {
        /// What follows the head: bytes in hand, or a run of a file, read as
        /// it is sent so a client that hangs up early costs nothing more.
        package enum Body: Sendable, Equatable {
            case data(Data)
            case file(URL, offset: Int, length: Int)

            var length: Int {
                switch self {
                case .data(let data): data.count
                case .file(_, _, let length): length
                }
            }
        }

        package let status: Int
        package let contentType: String
        package var headers: [String: String] = ["Cache-Control": "no-store"]
        package let body: Body

        package init(status: Int, contentType: String, headers: [String: String] = ["Cache-Control": "no-store"], body: Data) {
            self.init(status: status, contentType: contentType, headers: headers, body: .data(body))
        }

        private init(status: Int, contentType: String, headers: [String: String], body: Body) {
            self.status = status
            self.contentType = contentType
            self.headers = headers
            self.body = body
        }

        package static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return Response(status: status, contentType: "application/json", body: (try? encoder.encode(value)) ?? Data())
        }

        package static func error(_ status: Int, _ message: String) -> Response {
            json(["error": message], status: status)
        }

        /// A file that never changes under its name, in the byte range a
        /// `Range` header asks for, which a browser needs to play a video.
        package static func file(_ url: URL, contentType: String, range: String?) throws -> Response {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let length = values.fileSize else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url])
            }
            var headers = ["Cache-Control": "max-age=31536000, immutable", "Accept-Ranges": "bytes"]
            guard let range, let (start, end) = byteRange(range, length: length) else {
                return Response(status: 200, contentType: contentType, headers: headers, body: .file(url, offset: 0, length: length))
            }
            guard start < length, start <= end else {
                headers["Content-Range"] = "bytes */\(length)"
                return Response(status: 416, contentType: contentType, headers: headers, body: .data(Data()))
            }
            headers["Content-Range"] = "bytes \(start)-\(end)/\(length)"
            return Response(status: 206, contentType: contentType, headers: headers, body: .file(url, offset: start, length: end - start + 1))
        }

        /// `bytes=0-1`, `bytes=100-` or `bytes=-500`, clamped to the file.
        package static func byteRange(_ header: String, length: Int) -> (Int, Int)? {
            guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
            let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            if parts[0].isEmpty {
                guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
                return (max(0, length - suffix), length - 1)
            }
            guard let start = Int(parts[0]) else { return nil }
            let end = parts[1].isEmpty ? length - 1 : Int(parts[1]).map { min($0, length - 1) }
            return end.map { (start, $0) }
        }
    }
}

/// A small HTTP/1.1 server on the loopback interface: one request per
/// connection, bodies by `Content-Length`. Enough for one person's browser,
/// or an app under capture, talking to their own machine, and nothing else
/// can reach it.
package final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ProductPageKit.http")
    private let handle: @Sendable (Request) async -> Response

    /// - Parameter port: the port to listen on, or nil for any free one.
    package init(port: UInt16? = nil, handle: @escaping @Sendable (Request) async -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        listener = try NWListener(using: parameters)
        self.handle = handle
    }

    /// Starts listening and returns the port.
    package func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    package func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            let request = await read(connection)
            let response = if let request { await handle(request) } else { Response.error(400, "unreadable request") }
            let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 416: "Range Not Satisfiable",
                          500: "Internal Server Error", 502: "Bad Gateway"][response.status] ?? "Status"
            let headers = response.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
            let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\n"
                + "Content-Length: \(response.body.length)\r\n" + headers + "Connection: close\r\n\r\n"
            if await send(Data(head.utf8), on: connection), request?.method != "HEAD" {
                await send(response.body, on: connection)
            }
            connection.cancel()
        }
    }

    /// A file goes out a chunk at a time, and stops when the client has gone.
    private func send(_ body: Response.Body, on connection: NWConnection) async {
        switch body {
        case .data(let data):
            await send(data, on: connection)
        case .file(let url, let offset, let length):
            guard let file = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? file.close() }
            guard (try? file.seek(toOffset: UInt64(offset))) != nil else { return }
            var remaining = length
            while remaining > 0, let chunk = try? file.read(upToCount: min(remaining, Self.chunkSize)), !chunk.isEmpty {
                guard await send(chunk, on: connection) else { return }
                remaining -= chunk.count
            }
        }
    }

    private static let chunkSize = 1 << 20

    @discardableResult
    private func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    private func read(_ connection: NWConnection) async -> Request? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard let chunk = await receive(connection), !chunk.isEmpty else { return nil }
            buffer += chunk
            if buffer.count > 1 << 16 { return nil }
        }
        let headerEnd = buffer.range(of: separator)!
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            guard let chunk = await receive(connection), !chunk.isEmpty else { return nil }
            body += chunk
        }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body.prefix(length))
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, error in
                continuation.resume(returning: error == nil ? data : nil)
            }
        }
    }
}

/// Lets exactly one of several callbacks resume a continuation.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
