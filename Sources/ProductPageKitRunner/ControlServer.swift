import Foundation
import Network
import Synchronization
import ProductPageKitControl

/// What can happen to a launched app while the runner waits on it.
enum AppEvent: Sendable {
    case connected(RunnerConnection)
    case message(AppMessage)
    case closed
    case exited
}

/// Events in arrival order, and one waiter at a time with a deadline.
///
/// Posting is synchronous, so events posted from one queue arrive in the
/// order they happened there: a connection before what it carries, and what
/// it carries before it closes.
///
/// A deadline is how long the runner is willing to wait for something the app
/// announces. It never stands in for the announcement.
final class Mailbox: Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<AppEvent?, Never>
        let deadline: Task<Void, Never>
    }

    private struct State {
        var buffer: [AppEvent] = []
        var waiter: Waiter?
    }

    private let state = Mutex(State())

    func post(_ event: AppEvent) {
        let waiter = state.withLock { state in
            guard let waiter = state.waiter else {
                state.buffer.append(event)
                return Waiter?.none
            }
            state.waiter = nil
            return waiter
        }
        waiter?.deadline.cancel()
        waiter?.continuation.resume(returning: event)
    }

    /// The next event, or nil when `timeout` passes first. Throws when the
    /// task is cancelled.
    func next(within timeout: Duration) async throws -> AppEvent? {
        let id = UUID()
        let event = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let deadline = Task {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    self.expire(id)
                }
                let buffered = state.withLock { state in
                    guard state.buffer.isEmpty else { return Optional(state.buffer.removeFirst()) }
                    state.waiter = Waiter(id: id, continuation: continuation, deadline: deadline)
                    return nil
                }
                if let buffered {
                    deadline.cancel()
                    continuation.resume(returning: buffered)
                }
            }
        } onCancel: {
            expire(id)
        }
        try Task.checkCancellation()
        return event
    }

    private func expire(_ id: UUID) {
        let waiter = state.withLock { state in
            guard let waiter = state.waiter, waiter.id == id else { return Waiter?.none }
            state.waiter = nil
            return waiter
        }
        waiter?.deadline.cancel()
        waiter?.continuation.resume(returning: nil)
    }
}

/// The runner's end of one app's control connection.
///
/// Everything it posts, from announcing itself to closing, is posted on its
/// queue as it happens.
final class RunnerConnection: Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    /// Posts `.connected` before the connection starts, so nothing it
    /// receives can arrive ahead of it. Called on `queue`.
    init(_ connection: NWConnection, queue: DispatchQueue, mailbox: Mailbox) {
        self.connection = connection
        self.queue = queue
        mailbox.post(.connected(self))
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: mailbox.post(.closed)
            default: break
            }
        }
        connection.start(queue: queue)
        Self.receive(connection, decoder: LineDecoder<AppMessage>(), mailbox: mailbox)
    }

    func send(_ message: RunnerMessage) throws {
        connection.send(content: try LineCodec.encode(message), completion: .idempotent)
    }

    func close() {
        connection.cancel()
    }

    /// Reads on the connection's queue; each message is posted before the
    /// next read starts, so the mailbox sees them in order.
    private static func receive(_ connection: NWConnection, decoder: LineDecoder<AppMessage>, mailbox: Mailbox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: lineReadSize) { data, _, isComplete, error in
            var decoder = decoder
            for message in (data.flatMap { try? decoder.feed($0) }) ?? [] { mailbox.post(.message(message)) }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(connection, decoder: decoder, mailbox: mailbox)
            }
        }
    }
}

/// A loopback TCP listener for one worker. Each connection goes to the
/// mailbox of the launch that is waiting for it.
final class ControlListener: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    /// Set before each launch; touched only on `queue`.
    private var mailbox: Mailbox?

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.queue = queue
    }

    static func start() async throws -> ControlListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "ProductPageKit.control")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        let control = ControlListener(listener: listener, port: port, queue: queue)
        listener.newConnectionHandler = { [unowned control] connection in
            guard let mailbox = control.mailbox else { return connection.cancel() }
            _ = RunnerConnection(connection, queue: queue, mailbox: mailbox)
        }
        return control
    }

    /// Routes the next connections to `mailbox`.
    func expect(_ mailbox: Mailbox) {
        queue.sync { self.mailbox = mailbox }
    }

    func stop() {
        listener.cancel()
    }
}

/// Posts `.exited` when the process ends.
final class ProcessWatch: Sendable {
    private let source: any DispatchSourceProcess

    init(pid: Int32, mailbox: Mailbox) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { mailbox.post(.exited) }
        source.activate()
        // A process that ended before the source was armed never fires it.
        if kill(pid, 0) != 0, errno == ESRCH { mailbox.post(.exited) }
    }

    func cancel() {
        source.cancel()
    }
}
