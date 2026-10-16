import CoreGraphics
import Foundation
import ProductPageKitControl

/// One launch of an app under the runner's control: it connects and says
/// `hello`, then shows each scene asked for, then quits.
///
/// Every wait ends on something the app does (connecting, `ready`, `failed`,
/// closing, exiting) or on a deadline that turns into an error naming what
/// never happened. A scene waiting for the app to be in front has it
/// brought forward.
final class AppSession: Sendable {
    let hello: Hello
    private let mailbox: Mailbox
    private let connection: RunnerConnection
    private let watch: ProcessWatch?
    private let describedAs: String
    private let bringToFront: @Sendable () async -> Void

    /// How long an app may take to connect after it starts, and to draw a
    /// scene after `apply`. Generous: they bound a hang, not a launch.
    static let helloTimeout: Duration = .seconds(120)
    static let readyTimeout: Duration = .seconds(60)
    /// How long a test may take to put a scene up: it may launch apps and
    /// press its way through the system's screens first.
    static let testReadyTimeout: Duration = .seconds(240)
    static let quitTimeout: Duration = .seconds(15)
    /// How long an app may take to build a component and export it: longer
    /// than its own half minute to settle and half minute to hold still, so
    /// a component that does neither arrives with the app's reason.
    static let exportTimeout: Duration = .seconds(120)

    /// Waits for the app to connect through `mailbox` and say hello.
    ///
    /// - Parameter pid: the app's pid, when the runner launched it; its exit
    ///   is watched, and its hello must carry it. A test host started by
    ///   `xcodebuild` is matched by its hello alone, and whoever started it
    ///   posts `.exited` when `xcodebuild` ends.
    /// - Parameter bringToFront: brings the app forward when a scene waits
    ///   for it to be in front.
    init(mailbox: Mailbox, pid: Int32?, describedAs: String, bringToFront: @escaping @Sendable () async -> Void) async throws {
        let watch = pid.map { ProcessWatch(pid: $0, mailbox: mailbox) }
        var connection: RunnerConnection?
        while true {
            guard let event = try await mailbox.next(within: Self.helloTimeout) else {
                watch?.cancel()
                throw RunnerError.timedOut("\(describedAs) to connect")
            }
            switch event {
            case .connected(let new):
                if connection == nil { connection = new } else { new.close() }
            case .message(.hello(let hello)) where pid == nil || hello.pid == pid:
                guard let connection else { continue }
                self.hello = hello
                self.mailbox = mailbox
                self.connection = connection
                self.watch = watch
                self.describedAs = describedAs
                self.bringToFront = bringToFront
                return
            case .message:
                continue
            case .closed:
                connection = nil
            case .exited:
                watch?.cancel()
                throw RunnerError.appExited(describedAs, before: "it connected")
            }
        }
    }

    /// Asks for `request` and returns once the app reports it on screen.
    func show(_ request: SceneRequest, within timeout: Duration = readyTimeout) async throws -> Ready {
        try await ask(.apply(request), about: request, to: (do: "draw", did: "drew"), within: timeout) {
            if case .ready(let ready) = $0, ready.request == request { ready } else { nil }
        }
    }

    /// Where the scene on screen's highlights are, as fractions of what is
    /// photographed.
    func highlights(of request: SceneRequest) async throws -> [CGRect] {
        try await ask(.highlights(request), about: request, to: (do: "measure", did: "measured")) {
            if case .highlights(let highlights) = $0, highlights.request == request { highlights.rects } else { nil }
        }
    }

    /// The component, with nothing around it. A Mac app shows it in a window
    /// over black, then over white, and `photograph` takes each; anything
    /// else draws it itself.
    func export(_ request: ComponentRequest, photograph: (WindowInfo) async throws -> Frame) async throws -> CGImage {
        try connection.send(.export(request))
        var black: Frame?
        while true {
            guard let event = try await mailbox.next(within: Self.exportTimeout) else {
                throw RunnerError.timedOut("\(describedAs) to export \(request)")
            }
            switch event {
            case .message(.exported(let exported)) where exported.component == request:
                return try Frame(png: exported.png).image
            case .message(.showing(let shown)) where shown.component == request:
                let frame = try await photograph(shown.window)
                try connection.send(.taken(request))
                guard shown.backdrop == .white else {
                    black = frame
                    continue
                }
                guard let black, let image = Matte.transparent(black: black.image, white: frame.image) else {
                    throw RunnerError.mismatchedBackdrops(request.description)
                }
                return image
            case .message(.exportFailed(let failure)) where failure.component == request:
                throw RunnerError.componentFailed(request.description, failure.reason)
            case .message:
                continue
            case .closed, .exited:
                throw RunnerError.appExited(describedAs, before: "it exported \(request)")
            case .connected(let extra):
                extra.close()
            }
        }
    }

    /// Sends `message` and waits for the answer `match` picks out, or the
    /// app's failure to give it. A deadline that passes names what the scene
    /// last said it was waiting for.
    private func ask<Answer>(_ message: RunnerMessage, about request: SceneRequest, to verb: (do: String, did: String),
                             within timeout: Duration = readyTimeout, match: (AppMessage) -> Answer?) async throws -> Answer {
        try connection.send(message)
        var waitingFor: [Waiting.Reason] = []
        while true {
            guard let event = try await mailbox.next(within: timeout) else {
                let waiting = waitingFor.isEmpty ? "" : ", which was waiting for \(waitingFor.map(\.description).joined(separator: " and "))"
                throw RunnerError.timedOut("\(describedAs) to \(verb.do) \(request)\(waiting)")
            }
            switch event {
            case .message(let message):
                if let answer = match(message) { return answer }
                switch message {
                case .failed(let failure) where failure.request == request:
                    throw RunnerError.sceneFailed(request.description, failure.reason)
                case .waiting(let waiting) where waiting.request == request:
                    waitingFor = waiting.reasons
                    if waitingFor.contains(where: \.needsFront) { await bringToFront() }
                default:
                    continue
                }
            case .closed, .exited:
                throw RunnerError.appExited(describedAs, before: "it \(verb.did) \(request)")
            case .connected(let extra):
                extra.close()
            }
        }
    }

    /// Sends `quit` and waits for the app to go. Returns false when it did not
    /// within the deadline, for the caller to end it.
    @discardableResult
    func quit() async -> Bool {
        defer { watch?.cancel() }
        try? connection.send(.quit)
        while let event = try? await mailbox.next(within: Self.quitTimeout) {
            switch event {
            case .closed, .exited: return true
            case .connected(let extra): extra.close()
            case .message: continue
            }
        }
        connection.close()
        return false
    }

    /// Stops when the app is not the one the run needs.
    /// - Parameter bundleID: the project's, or nil for a test whose runner
    ///   is a process of its own.
    func check(bundleID: String?, platform: ControlPlatform, scenes: [String]) throws {
        let problems = Self.problems(hello, bundleID: bundleID, platform: platform, scenes: scenes)
        guard problems.isEmpty else { throw RunnerError.appMismatch(problems) }
    }

    /// Problems with `hello` against what the run needs from the app.
    static func problems(_ hello: Hello, bundleID: String?, platform: ControlPlatform, scenes: [String]) -> [String] {
        var problems: [String] = []
        if hello.version != ControlProtocol.version {
            problems.append("the app speaks control protocol \(hello.version) and this runner \(ControlProtocol.version); update ProductPageKit in one of them")
        }
        if let bundleID, hello.bundleID != bundleID { problems.append("the app is \(hello.bundleID), and the project is \(bundleID)") }
        if hello.platform != platform { problems.append("the app runs on \(hello.platform.rawValue), and the runner expected \(platform.rawValue)") }
        let known = Set(hello.scenes.map(\.name))
        let missing = scenes.filter { !known.contains($0) }
        if !missing.isEmpty {
            problems.append("the app has no scene named \(missing.joined(separator: ", ")). Its scenes: \(hello.scenes.map(\.name).joined(separator: ", "))")
        }
        return problems
    }
}
