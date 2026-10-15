#if DEBUG
import Foundation
import Network
import os
import ProductPageKitControl

/// The app's end of the control channel: a TCP connection to the runner on
/// the loopback interface, delivering on the main queue in arrival order.
@MainActor
final class ControlConnection {
    private let connection: NWConnection
    private var decoder = LineDecoder<RunnerMessage>()
    private let onMessage: @MainActor (RunnerMessage) -> Void
    private let onClose: @MainActor () -> Void

    init(host: String, port: UInt16, onMessage: @escaping @MainActor (RunnerMessage) -> Void,
         onClose: @escaping @MainActor () -> Void) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error):
                    Self.log.error("control connection failed: \(error)")
                    self?.close()
                case .cancelled:
                    self?.onClose()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    /// Queued until the connection is up.
    func send(_ message: AppMessage) {
        do {
            connection.send(content: try LineCodec.encode(message), completion: .contentProcessed { error in
                if let error { Self.log.error("could not send to the runner: \(error)") }
            })
        } catch {
            Self.log.error("could not encode \(String(describing: message)): \(error)")
        }
    }

    func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: lineReadSize) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try self.decoder.feed(data) { self.onMessage(message) }
                    } catch {
                        Self.log.error("unreadable message from the runner: \(error)")
                    }
                }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    nonisolated static let log = Logger(subsystem: "ProductPageKit", category: "capture")
}
#endif
