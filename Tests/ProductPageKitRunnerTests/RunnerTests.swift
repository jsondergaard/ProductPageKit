import CoreGraphics
import Foundation
import Network
import Synchronization
import ProductPageKitControl
@testable import ProductPageKitCore
import Testing
@testable import ProductPageKitRunner

@Suite struct FrameStabilityTests {
    /// A 100 × 100 grey image with `marked` pixels painted `mark`, white
    /// unless named, from the top left.
    func image(marked: Int = 0, width: Int = 100, mark: [UInt8] = [255, 255, 255, 255]) -> CGImage {
        var pixels = [UInt8](repeating: 128, count: width * 100 * 4)
        for pixel in 0..<marked { pixels.replaceSubrange(pixel * 4..<pixel * 4 + 4, with: mark) }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: 100, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A display that is off photographs black, and a frame of one flat
    /// colour shows nothing either.
    @Test func aFlatFrameShowsNothing() throws {
        #expect(!(try Frame(image: image(marked: 100 * 100, mark: [0, 0, 0, 255]))).showsContent)
        #expect(!(try Frame(image: image())).showsContent)
        #expect(try Frame(image: image(marked: 5000)).showsContent)
        // Lighter and darker than the first pixel both count.
        #expect(try Frame(image: image(marked: 5000, mark: [0, 0, 0, 255])).showsContent)
        #expect(try Frame(image: image(marked: 100 * 100 - 1, mark: [0, 0, 0, 255])).showsContent)
    }

    /// A flat frame is never stored, whatever the platform.
    @Test func aFlatCaptureIsRefused() throws {
        let flat = try Frame(image: image())
        for platform in [Platform.iPhone(), .appleTV(), .mac(window: CGSize(width: 100, height: 100))] {
            #expect {
                try flat.check("home in en", on: platform)
            } throws: { error in
                guard case RunnerError.blankCapture("home in en", platform.name) = error else { return false }
                return true
            }
        }
    }

    /// An iPhone Duo folded, or an iPhone on its side, photographs turned
    /// the wrong way. A Mac window is any shape it is given.
    @Test func aCaptureTurnedTheOtherWayIsRefused() throws {
        let wide = try Frame(image: image(marked: 5000, width: 150))
        let tall = try Frame(image: image(marked: 5000, width: 60))
        try wide.check("home in en", on: .iPhoneDuo())
        try wide.check("home in en", on: .appleTV())
        try tall.check("home in en", on: .iPhone())
        try tall.check("home in en", on: .iPad())
        try tall.check("home in en", on: .mac(window: CGSize(width: 60, height: 100)))
        try wide.check("home in en", on: .mac(window: CGSize(width: 150, height: 100)))
        for (frame, platform) in [(tall, Platform.iPhoneDuo()), (tall, .appleTV()), (wide, .iPhone()), (wide, .iPad())] {
            #expect {
                try frame.check("home in en", on: platform)
            } throws: { error in
                guard case RunnerError.misorientedCapture("home in en", platform.name, _, let landscape) = error else { return false }
                return landscape == (platform.kind == .iPhoneDuo || platform.kind == .appleTV)
            }
        }
    }

    @Test func aRefusedCaptureSaysWhatCameOut() {
        #expect(RunnerError.misorientedCapture("home in en", platform: "iPhone Duo", size: CGSize(width: 2007, height: 2853),
                                               landscape: true).description
                == "home in en on iPhone Duo came out 2007 × 2853, where iPhone Duo captures landscape. It was not kept.")
    }

    @Test func framesMatchWithinTheTolerance() {
        let stability = FrameStability(tolerance: 0.001)
        #expect(stability.matches(image(), image()))
        #expect(stability.matches(image(), image(marked: 10)))
        #expect(!stability.matches(image(), image(marked: 11)))
        #expect(!stability.matches(image(), image(width: 101)))
    }

    /// A video playing moves on purpose; the rest of the frame decides.
    @Test func whatMovesOnPurposeIsLeftOut() {
        let stability = FrameStability(tolerance: 0)
        // The first 500 pixels are the top five rows.
        #expect(!stability.matches(image(), image(marked: 500)))
        #expect(stability.matches(image(), image(marked: 500), ignoring: [CGRect(x: 0, y: 0, width: 1, height: 0.05)]))
        #expect(!stability.matches(image(), image(marked: 600), ignoring: [CGRect(x: 0, y: 0, width: 1, height: 0.05)]))
    }

    @Test func settlingStopsAtTheFirstTwoFramesThatMatch() async throws {
        let frames = try [image(marked: 5000), image(marked: 3000), image(marked: 1000), image(marked: 1000), image()].map(Frame.init(image:))
        var taken = 0
        let frame = try await FrameStability().settle("inbox") {
            defer { taken += 1 }
            return frames[taken]
        }
        #expect(taken == 4)
        #expect(frame.png == frames[3].png)
    }

    /// A view in a cover mounts after the app says ready, so where it moves is
    /// asked again once two frames differ.
    @Test func settlingAsksAgainWhereWhatMovesIsWhenFramesDiffer() async throws {
        let frames = try [image(marked: 5000), image(marked: 3000)].map(Frame.init(image:))
        var taken = 0, asked = 0
        let frame = try await FrameStability().settle("a video in en", remeasuring: {
            asked += 1
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        }, capture: {
            defer { taken += 1 }
            return frames[taken]
        })
        #expect(taken == 2)
        #expect(asked == 1)
        #expect(frame.png == frames[1].png)
    }

    /// Straight after the simulator's bridge restarts, its screenshots come
    /// without the display's mask, which blacks the corners.
    @Test func aScreenshotWithItsCornersMaskedIsComposedAsUsual() throws {
        #expect(try Frame(image: image(marked: 1, mark: [0, 0, 0, 255])).isMasked)
        #expect(try !Frame(image: image(marked: 1)).isMasked)
        #expect(try !Frame(image: image()).isMasked)
    }

    /// It fails, and leaves its last frames and what changed between them.
    @Test func aSceneThatNeverSettlesFails() async throws {
        let evidence = FileManager.default.temporaryDirectory.appending(path: "FrameStabilityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: evidence) }
        var marked = 0
        let error = await #expect(throws: RunnerError.self) {
            try await FrameStability(maximumFrames: 5, evidence: evidence).settle("a spinner in en") {
                marked += 500
                return try Frame(image: image(marked: marked))
            }
        }
        #expect(marked == 3000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: evidence.path).sorted()
                == ["a-spinner-in-en-1.png", "a-spinner-in-en-2.png", "a-spinner-in-en-changed.png"])
        #expect(error?.description.contains("a-spinner-in-en-changed.png") == true)
    }
}

@Suite struct CaptureLedgerTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CaptureLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aCaptureIsCurrentUnderTheStampItWasTakenUnderWhileItsFileIsThere() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appending(path: "01_inbox.png")
        let file = folder.appending(path: "ledger/en.json")
        var ledger = CaptureLedger(file: file, stamp: "a", force: false)
        try Data().write(to: png)
        #expect(!ledger.isCurrent("shot/01_inbox.png", files: [png]))
        try ledger.record("shot/01_inbox.png")
        #expect(ledger.isCurrent("shot/01_inbox.png", files: [png]))
        // Kept across runs, until the inputs change, the file goes or a run forces.
        #expect(CaptureLedger(file: file, stamp: "a", force: false).isCurrent("shot/01_inbox.png", files: [png]))
        #expect(!CaptureLedger(file: file, stamp: "b", force: false).isCurrent("shot/01_inbox.png", files: [png]))
        #expect(!CaptureLedger(file: file, stamp: "a", force: true).isCurrent("shot/01_inbox.png", files: [png]))
        try FileManager.default.removeItem(at: png)
        #expect(!CaptureLedger(file: file, stamp: "a", force: false).isCurrent("shot/01_inbox.png", files: [png]))
    }

    @Test func aShotAndAComponentOfOneNameAreTwoCaptures() {
        #expect(CaptureLedger.shotKey("basket.png") != CaptureLedger.componentKey("basket.png"))
    }

    /// The app's bytes, the extensions' and the UI tests' runners', by path and
    /// content; nothing else in the products folder.
    @Test func theBundlesDigestChangesWithAnyByteOfAnyBundle() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: app.appending(path: "Sample"))
        try FileManager.default.createSymbolicLink(atPath: app.appending(path: "Current").path, withDestinationPath: "Sample")
        let before = CaptureFingerprints.digest(ofBundlesIn: folder)
        #expect(CaptureFingerprints.digest(ofBundlesIn: folder) == before)
        try Data("notes".utf8).write(to: folder.appending(path: "build.log"))
        #expect(CaptureFingerprints.digest(ofBundlesIn: folder) == before)
        try Data("binary2".utf8).write(to: app.appending(path: "Sample"))
        let changed = CaptureFingerprints.digest(ofBundlesIn: folder)
        #expect(changed != before)
        try FileManager.default.removeItem(at: app.appending(path: "Current"))
        try FileManager.default.createSymbolicLink(atPath: app.appending(path: "Current").path, withDestinationPath: "Other")
        #expect(CaptureFingerprints.digest(ofBundlesIn: folder) != changed)
        try FileManager.default.createDirectory(at: folder.appending(path: "SampleUITests-Runner.app"), withIntermediateDirectories: true)
        try Data("tests".utf8).write(to: folder.appending(path: "SampleUITests-Runner.app/Runner"))
        let withRunner = CaptureFingerprints.digest(ofBundlesIn: folder)
        try Data("tests2".utf8).write(to: folder.appending(path: "SampleUITests-Runner.app/Runner"))
        #expect(CaptureFingerprints.digest(ofBundlesIn: folder) != withRunner)
    }

    /// The locales left keep the target's simulators, one more for the
    /// tests' screens, and never more than there is work for.
    @Test func theLocalesLeftKeepTheTargetsSimulators() throws {
        let example = project(locales: ["en", "da", "de"])
        let plan = try CapturePlan(project: example, request: CaptureRequest(platforms: [example.platforms[0]], locales: example.locales, workers: 2),
                                   machine: Machine(cores: 8, memory: 64 << 30))
        let target = plan.targets[0]
        let (en, da, de) = (example.locales[0], example.locales[1], example.locales[2])
        #expect(target.workers == 2)
        #expect(target.locales == [en, da, de])
        #expect(ScreenshotRunner.simulators(for: target.taking([]), testing: false) == 1)
        #expect(ScreenshotRunner.simulators(for: target.taking([de]), testing: false) == 1)
        #expect(ScreenshotRunner.simulators(for: target.taking([en, da, de]), testing: false) == 2)
        // The tests' screens take one of the two, which then takes locales.
        #expect(ScreenshotRunner.simulators(for: target.taking([]), testing: true) == 1)
        #expect(ScreenshotRunner.simulators(for: target.taking([de]), testing: true) == 2)
        #expect(target.taking([da]).locales == [da])
        #expect(target.taking([da]).workers == 2)
        #expect(target.taking([da]).shots == target.shots)
        #expect(!plan.force)
        #expect(try CapturePlan(project: example, request: CaptureRequest(platforms: [example.platforms[0]], locales: example.locales, force: true),
                                machine: Machine(cores: 8, memory: 64 << 30)).force)
    }
}

@Suite struct MacLaunchTests {
    /// RunningBoard's "prevent launch" assertion arrives wrapped in Launch
    /// Services' own errors, and passes; any other failure is the caller's.
    @Test func aLaunchRefusedByRunningBoardIsRetried() {
        let refused = NSError(domain: "RBSRequestErrorDomain", code: 7)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -10699, userInfo: [NSUnderlyingErrorKey: refused]),
        ])
        #expect(MacCapture.isLaunchRefused(wrapped))
        #expect(!MacCapture.isLaunchRefused(NSError(domain: NSCocoaErrorDomain, code: 4)))
    }
}

@Suite struct LockTests {
    @Test func aSecondRunIsRefusedUntilTheFirstReleases() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitLockTests-\(UUID().uuidString)/ios.lock")
        let first = try Lock(file, purpose: "capture")
        #expect(throws: RunnerError.self) { try Lock(file, purpose: "capture") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "\(getpid())\n")
        first.release()
        try Lock(file, purpose: "capture").release()
    }

    @Test func aWaitingRunTakesTheLockOnceTheFirstReleases() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitLockTests-\(UUID().uuidString)/xcodebuild.lock")
        let first = try Lock(file, purpose: "build")
        let announced = Mutex<[Int32?]>([])
        let second = Task { try await Lock.waiting(for: file, poll: .milliseconds(10)) { holder in announced.withLock { $0.append(holder) } } }
        try await Task.sleep(for: .milliseconds(100))
        first.release()
        let lock = try await second.value
        #expect(announced.withLock { $0 } == [getpid()])
        #expect(throws: RunnerError.self) { try Lock(file, purpose: "build") }
        lock.release()
    }
}

@Suite struct HelloTests {
    let hello = Hello(pid: 1, bundleID: "com.example.app", platform: .iOS,
                      scenes: [SceneDescription(name: "inbox", relaunch: false), SceneDescription(name: "panel", relaunch: true)],
                      variantsRelaunch: false)

    @Test func aMatchingAppHasNoProblems() {
        #expect(AppSession.problems(hello, bundleID: "com.example.app", platform: .iOS, scenes: ["inbox", "panel"]).isEmpty)
    }

    @Test func aRenamedSceneStopsTheRunBeforeAnyCapture() {
        #expect(AppSession.problems(hello, bundleID: "com.example.app", platform: .iOS, scenes: ["inbox", "quiet"])
                == ["the app has no scene named quiet. Its scenes: inbox, panel"])
    }

    @Test func anotherAppPlatformOrVersionIsReported() {
        var other = hello
        other.version = ControlProtocol.version + 1
        let problems = AppSession.problems(other, bundleID: "com.example.other", platform: .macOS, scenes: [])
        #expect(problems.count == 3)
    }

    /// A UI test's runner is a process of its own, so only its platform and
    /// scenes are checked.
    @Test func aTestsRunnerIsNotHeldToTheAppsBundle() {
        var runner = hello
        runner.bundleID = "com.example.uitests.xctrunner"
        #expect(AppSession.problems(runner, bundleID: nil, platform: .iOS, scenes: ["inbox"]).isEmpty)
        #expect(AppSession.problems(runner, bundleID: nil, platform: .iOS, scenes: ["menu"]).count == 1)
    }
}

@Suite struct MailboxTests {
    @Test func eventsArriveInOrderAndAWaitEndsAtItsDeadline() async throws {
        let mailbox = Mailbox()
        mailbox.post(.closed)
        mailbox.post(.exited)
        guard case .closed = try await mailbox.next(within: .seconds(1)) else { Issue.record("expected closed"); return }
        guard case .exited = try await mailbox.next(within: .seconds(1)) else { Issue.record("expected exited"); return }
        #expect(try await mailbox.next(within: .milliseconds(50)) == nil)
    }
}

/// The runner's side of the protocol over a real loopback connection, with
/// this test playing the app.
@Suite struct ControlSessionTests {
    final class FakeApp: @unchecked Sendable {
        let connection: NWConnection
        private var decoder = LineDecoder<RunnerMessage>()
        private var received: [RunnerMessage] = []
        private let queue = DispatchQueue(label: "FakeApp")

        init(port: UInt16) {
            connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: queue)
        }

        func send(_ message: AppMessage) throws {
            connection.send(content: try LineCodec.encode(message), completion: .idempotent)
        }

        /// Ends the stream after what was sent, as an app that exits does.
        func finish() {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }

        func next() async throws -> RunnerMessage {
            if !received.isEmpty { return received.removeFirst() }
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
                }
            }
            received += try decoder.feed(data)
            return try await next()
        }
    }

    /// An app says hello as soon as it connects. Posted from tasks, a busy
    /// runner once saw the hello before the connection and dropped it.
    @Test func aConnectionArrivesBeforeWhatItCarriesAndClosesAfter() async throws {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        for attempt in 0..<50 {
            let mailbox = Mailbox()
            listener.expect(mailbox)
            let app = FakeApp(port: listener.port)
            defer { app.connection.cancel() }
            try app.send(.hello(Hello(pid: Int32(attempt), bundleID: "com.example.app", platform: .iOS, scenes: [],
                                      variantsRelaunch: false)))
            try app.send(.ready(Ready(SceneRequest(scene: "inbox"), window: nil)))
            app.finish()
            var events: [String] = []
            while let event = try await mailbox.next(within: .seconds(5)) {
                switch event {
                case .connected: events.append("connected")
                case .message(.hello): events.append("hello")
                case .message(.ready): events.append("ready")
                case .message: events.append("another message")
                case .closed: events.append("closed")
                case .exited: events.append("exited")
                }
                if case .closed = event { break }
            }
            #expect(events == ["connected", "hello", "ready", "closed"], "attempt \(attempt)")
        }
    }

    /// A process standing in for the app's, which `quit` waits to end.
    static func process() throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["600"]
        try process.run()
        return process
    }

    @Test func helloThenEachSceneThenQuit() async throws {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let app = FakeApp(port: listener.port)
        let process = try Self.process()
        defer { process.terminate() }
        let hello = Hello(pid: process.processIdentifier, bundleID: "com.example.app", platform: .iOS,
                          scenes: [SceneDescription(name: "inbox", relaunch: false), SceneDescription(name: "broken", relaunch: false)],
                          variantsRelaunch: false)
        try app.send(.hello(hello))
        let session = try await AppSession(mailbox: mailbox, pid: process.processIdentifier, describedAs: "the fake app") {}
        #expect(session.hello == hello)

        let inbox = SceneRequest(scene: "inbox")
        let frame = try Frame(image: FrameStabilityTests().image(width: 200))
        async let photographed = session.photograph(inbox) { ready in
            #expect(ready.request == inbox)
            return frame
        }
        #expect(try await app.next() == .apply(inbox))
        // A stale answer for another scene is not this one's.
        try app.send(.ready(Ready(SceneRequest(scene: "other"), window: nil)))
        try app.send(.ready(Ready(inbox, window: nil)))
        // Measured once photographed, in the photograph's pixels.
        #expect(try await app.next() == .photographed(inbox))
        try app.send(.highlights(SceneHighlights(inbox, rects: [CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1)])))
        #expect(try await photographed.highlights == Highlights([CGRect(x: 20, y: 40, width: 160, height: 10)]))

        let broken = SceneRequest(scene: "broken")
        let failure = Task { try await session.photograph(broken) { _ in frame } }
        #expect(try await app.next() == .apply(broken))
        try app.send(.failed(Failure(broken, reason: "no fixture")))
        await #expect(throws: RunnerError.self) { try await failure.value }

        // Gone once its process ends, not when its connection closes.
        let quit = Task { await session.quit() }
        #expect(try await app.next() == .quit)
        app.connection.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(process.isRunning)
        process.terminate()
        #expect(await quit.value)
    }

    @Test func movingViewsAreAskedForOfTheSceneOnScreen() async throws {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let app = FakeApp(port: listener.port)
        try app.send(.hello(Hello(pid: getpid(), bundleID: "com.example.app", platform: .iOS, scenes: [], variantsRelaunch: false)))
        let session = try await AppSession(mailbox: mailbox, pid: getpid(), describedAs: "the fake app") {}
        let inbox = SceneRequest(scene: "inbox")
        let rects = [CGRect(x: 0, y: 0.1, width: 1, height: 0.8)]
        async let moving = session.moving(inbox)
        #expect(try await app.next() == .measureMoving(inbox))
        // A stale answer for another scene is not this one's.
        try app.send(.moving(SceneMoving(SceneRequest(scene: "other"), rects: [])))
        try app.send(.moving(SceneMoving(inbox, rects: rects)))
        #expect(try await moving == rects)
    }

    /// The system can send a freshly launched app behind the home screen
    /// after it drew, and the frames then settle on the home screen. The app
    /// says so when it hears the scene was photographed, and the runner
    /// brings it forward and takes it again, a few times at most.
    @Test func aSceneThatLeftTheFrontIsPhotographedAgain() async throws {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let app = FakeApp(port: listener.port)
        try app.send(.hello(Hello(pid: getpid(), bundleID: "com.example.app", platform: .tvOS, scenes: [], variantsRelaunch: true)))
        let fronts = Fronts()
        let session = try await AppSession(mailbox: mailbox, pid: getpid(), describedAs: "the fake app") { await fronts.add() }
        let home = try Frame(image: FrameStabilityTests().image(marked: 1)), scene = try Frame(image: FrameStabilityTests().image(marked: 2))
        let photographs = Photographs([home, scene])

        let detail = SceneRequest(scene: "detail", variant: "blue")
        async let photographed = session.photograph(detail) { _ in await photographs.next() }
        #expect(try await app.next() == .apply(detail))
        try app.send(.ready(Ready(detail, window: nil)))
        #expect(try await app.next() == .photographed(detail))
        try app.send(.leftFront(detail))
        #expect(try await app.next() == .apply(detail))
        try app.send(.waiting(Waiting(detail, reasons: [.activeScene])))
        try app.send(.ready(Ready(detail, window: nil)))
        #expect(try await app.next() == .photographed(detail))
        try app.send(.highlights(SceneHighlights(detail, rects: [])))
        #expect(try await photographed.frame.png == scene.png)
        #expect(await fronts.count == 1)

        let settings = SceneRequest(scene: "settings")
        let restless = Task { try await session.photograph(settings) { _ in home } }
        for _ in 0..<AppSession.photographAttempts {
            #expect(try await app.next() == .apply(settings))
            try app.send(.ready(Ready(settings, window: nil)))
            #expect(try await app.next() == .photographed(settings))
            try app.send(.leftFront(settings))
        }
        let error = await #expect(throws: RunnerError.self) { try await restless.value }
        #expect(error?.description == "the fake app left the front before settings was photographed, 3 times in a row.")
    }

    /// A launch can land behind the home screen, and a Mac app behind
    /// whatever is in front: the scene says it waits for the front, and the
    /// runner brings the app forward each time it does.
    @Test func aSceneWaitingForTheFrontHasItsAppBroughtForward() async throws {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let app = FakeApp(port: listener.port)
        try app.send(.hello(Hello(pid: getpid(), bundleID: "com.example.app", platform: .tvOS, scenes: [], variantsRelaunch: true)))
        let fronts = Fronts()
        let session = try await AppSession(mailbox: mailbox, pid: getpid(), describedAs: "the fake app") { await fronts.add() }

        let frame = try Frame(image: FrameStabilityTests().image())
        let detail = SceneRequest(scene: "detail", variant: "blue")
        async let photographed = session.photograph(detail) { _ in frame }
        #expect(try await app.next() == .apply(detail))
        try app.send(.waiting(Waiting(detail, reasons: [.conditions, .activeScene])))
        try app.send(.waiting(Waiting(detail, reasons: [.conditions])))
        try app.send(.waiting(Waiting(detail, reasons: [.activeScene])))
        try app.send(.ready(Ready(detail, window: nil)))
        #expect(try await app.next() == .photographed(detail))
        try app.send(.highlights(SceneHighlights(detail, rects: [])))
        #expect(try await photographed.frame.png == frame.png)
        #expect(await fronts.count == 2)

        // A scene that never gets the front says so when the runner gives up.
        let settings = SceneRequest(scene: "settings")
        let late = Task { try await session.photograph(settings, within: .milliseconds(300)) { _ in frame } }
        #expect(try await app.next() == .apply(settings))
        try app.send(.waiting(Waiting(settings, reasons: [.keyWindow])))
        let error = await #expect(throws: RunnerError.self) { try await late.value }
        #expect(error?.description == "Gave up waiting for the fake app to draw settings, which was waiting for its window to become key.")
        #expect(await fronts.count == 3)
    }

    actor Fronts {
        var count = 0
        func add() { count += 1 }
    }

    /// A simulator app sends its component; a Mac app shows it over black,
    /// then white, and the runner photographs each and mattes the pair.
    @Test func componentsArriveDrawnOrShown() async throws {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let app = FakeApp(port: listener.port)
        try app.send(.hello(Hello(pid: getpid(), bundleID: "com.example.app", platform: .macOS, scenes: [], variantsRelaunch: true)))
        let session = try await AppSession(mailbox: mailbox, pid: getpid(), describedAs: "the fake app") {}
        let tile = FrameStabilityTests().image(marked: 0)

        let drawn = ComponentRequest(name: "sources")
        async let exported = session.export(drawn) { _ in throw RunnerError.componentWindowOffMac("sources") }
        #expect(try await app.next() == .export(drawn))
        try app.send(.exported(ExportedComponent(drawn, png: try Frame(image: tile).png)))
        #expect(try await exported.width == 100)

        let shown = ComponentRequest(name: "card", state: "1")
        let window = WindowInfo(number: 7, frame: CGRect(x: 0, y: 0, width: 2, height: 1))
        let photographs = Photographs([try Frame(image: Self.pixels([0, 0, 0, 255, 200, 0, 0, 255])),
                                       try Frame(image: Self.pixels([255, 255, 255, 255, 200, 0, 0, 255]))])
        async let matted = session.export(shown) { _ in await photographs.next() }
        #expect(try await app.next() == .export(shown))
        try app.send(.showing(ShownComponent(shown, window: window, backdrop: .black)))
        #expect(try await app.next() == .taken(shown))
        try app.send(.showing(ShownComponent(shown, window: window, backdrop: .white)))
        #expect(try await app.next() == .taken(shown))
        let image = try await matted
        let pixels = try #require(FrameStability.pixels(image))
        // The backdrop shows through the first pixel, which is clear; the
        // second is red whatever is behind it.
        #expect(Array(pixels[0..<4]) == [0, 0, 0, 0])
        #expect(Array(pixels[4..<8]) == [200, 0, 0, 255])

        let missing = ComponentRequest(name: "nothing")
        let failure = Task { try await session.export(missing) { _ in throw RunnerError.componentWindowOffMac("nothing") } }
        #expect(try await app.next() == .export(missing))
        try app.send(.exportFailed(ComponentFailure(missing, reason: "the app has no component nothing")))
        await #expect(throws: RunnerError.self) { try await failure.value }
    }

    /// Frames handed out in order.
    actor Photographs {
        var frames: [Frame]
        init(_ frames: [Frame]) { self.frames = frames }
        func next() -> Frame { frames.removeFirst() }
    }

    /// One row of RGBA pixels.
    static func pixels(_ bytes: [UInt8]) -> CGImage {
        CGImage.rgba(bytes, width: bytes.count / 4, height: 1)!
    }
}

@Suite struct StatusBarTimeTests {
    /// The minute the run started, in UTC, which the simulator shows in its
    /// own region.
    @Test func aRunShowsNineFortyOneOrTheMinuteItStarted() {
        let start = Date(timeIntervalSince1970: 1_792_088_725)
        #expect(ScreenshotRunner.statusBarTime(.nineFortyOne, startedAt: start) == "9:41")
        #expect(ScreenshotRunner.statusBarTime(.captureStart, startedAt: start) == "2026-10-15T18:25:00.000Z")
    }
}

@Suite struct ComponentImageTests {
    /// A `width` × `height` image, clear but for white at each of `drawn`'s
    /// (x, y), counted from the top-left.
    static func image(width: Int, height: Int, drawn: [(Int, Int)]) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (x, y) in drawn {
            let index = (y * width + x) * 4
            bytes.replaceSubrange(index..<index + 4, with: [255, 255, 255, 255])
        }
        return CGImage.rgba(bytes, width: width, height: height)!
    }

    @Test func trimmingKeepsWhatIsDrawn() throws {
        let trimmed = try #require(CGImage.trimmingTransparentEdges([Self.image(width: 5, height: 4, drawn: [(1, 1), (2, 1), (1, 2)])]).first)
        #expect(trimmed.width == 2)
        #expect(trimmed.height == 2)
        let clear = Self.image(width: 2, height: 2, drawn: [])
        #expect(CGImage.trimmingTransparentEdges([clear]).first?.width == 2)
    }

    /// A state that draws further out, as a selected tile's shadow does,
    /// widens every state's frame, and each keeps its place in it.
    @Test func statesShareOneFrame() throws {
        let plain = Self.image(width: 6, height: 3, drawn: [(2, 1), (3, 1)])
        let selected = Self.image(width: 6, height: 3, drawn: [(1, 1), (2, 1), (3, 1), (4, 2)])
        let trimmed = CGImage.trimmingTransparentEdges([plain, selected])
        #expect(trimmed.map(\.width) == [4, 4])
        #expect(trimmed.map(\.height) == [2, 2])
        let pixels = try #require(FrameStability.pixels(trimmed[0]))
        #expect(pixels[3] == 0)
        #expect(pixels[4 + 3] == 255)
    }

    /// A shorter state is padded below, from the top-left corner they share.
    @Test func aSmallerStateIsPaddedToTheFrame() throws {
        let short = Self.image(width: 3, height: 2, drawn: [(0, 0)])
        let tall = Self.image(width: 3, height: 4, drawn: [(0, 0), (0, 3)])
        let trimmed = CGImage.trimmingTransparentEdges([short, tall])
        #expect(trimmed.map(\.height) == [4, 4])
        let pixels = try #require(FrameStability.pixels(trimmed[0]))
        #expect(pixels[3] == 255)
        #expect(pixels[3 * 4 + 3] == 0)
    }

    @Test func oneStaleStateRetakesTheComponentsOthers() {
        let all = [Component("detail", state: "0"), Component("detail", state: "1"), Component("badges"),
                   Component("detail", state: "0", variant: "plex")]
        let stale = ScreenshotRunner.staleComponents(all) { $0 != Component("detail", state: "1") }
        #expect(stale.map(\.fileName) == ["detail@0", "detail@1"])
    }

    @Test func statesGroupByComponentInOrder() {
        let groups = ScreenshotRunner.stateGroups([
            Component("detail", state: "0"), Component("badges"), Component("detail", state: "1"),
            Component("detail", state: "0", variant: "plex"), Component("detail"),
        ])
        #expect(groups.map { $0.map(\.fileName) } == [
            ["detail@0", "detail@1", "detail"], ["badges"], ["detail@0-plex"],
        ])
    }

    @Test func halfOpaquePixelsKeepTheirColour() throws {
        // Grey at half opacity: black shows through as 64, white as 191.
        let black = CGImage.rgba([64, 64, 64, 255], width: 1, height: 1)!
        let white = CGImage.rgba([191, 191, 191, 255], width: 1, height: 1)!
        let matted = try #require(Matte.transparent(black: black, white: white))
        let pixel = try #require(FrameStability.pixels(matted))
        #expect(pixel[3] == 128)
        #expect(pixel[0] == 64)
        #expect(Matte.transparent(black: black, white: CGImage.rgba([0, 0, 0, 255, 0, 0, 0, 255], width: 2, height: 1)!) == nil)
    }
}

@Suite struct LocalePreferencesTests {
    let english = StoreLocale("en", store: "en-US")

    @Test func aStoreLocaleIsItsCodeAndRegion() {
        let preferences = LocalePreferences(english)
        #expect(preferences.languages == ["en"])
        #expect(preferences.locale == "en_US")
        #expect(preferences.launchArguments == ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
    }

    /// Mexico's storefront shows the app in Latin American Spanish, in
    /// Mexico's region.
    @Test func aStoreOnlyLocaleRunsInTheAppsLanguage() {
        let preferences = LocalePreferences(StoreLocale("es-MX", store: "es-MX", app: "es-419"))
        #expect(preferences.launchArguments == ["-AppleLanguages", "(es-419)", "-AppleLocale", "es_MX"])
    }

    @Test func applyingReplacesThePairAndKeepsEverythingElse() throws {
        let host: [String: Any] = ["AppleLanguages": ["en-DK", "da-DK"], "AppleLocale": "en_DK", "AddingEmojiKeybordHandled": true]
        #expect(LocalePreferences(host) != LocalePreferences(english))
        let applied = LocalePreferences(english).applied(to: host)
        #expect(LocalePreferences(applied) == LocalePreferences(english))
        #expect(applied["AddingEmojiKeybordHandled"] as? Bool == true)
        #expect(applied.count == 3)
    }

    @Test func preferencesWithoutBothKeysHoldNoLocale() {
        #expect(LocalePreferences(["AppleLocale": "da_DK"]) == nil)
        #expect(LocalePreferences(["AppleLanguages": "da", "AppleLocale": "da_DK"]) == nil)
    }

    /// The file a simulator boots from, written as the runner writes it
    /// between a shutdown and a boot.
    @Test func aDeviceBootsInTheLocaleWrittenToItsGlobalPreferences() throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitLocaleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let device = Simulators.Device(udid: "A", name: "worker", state: "Shutdown", isAvailable: true,
                                       deviceTypeIdentifier: nil, dataPath: data.path)
        try FileManager.default.createDirectory(at: device.globalPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let host: [String: Any] = ["AppleLanguages": ["en-DK"], "AppleLocale": "en_DK", "AppleLanguagesSchemaVersion": 5400]
        try PropertyListSerialization.data(fromPropertyList: host, format: .binary, options: 0).write(to: device.globalPreferences)

        let simulators = Simulators()
        #expect(try simulators.locale(of: device) == LocalePreferences(host))
        let danish = LocalePreferences(StoreLocale("da", store: "da"))
        try simulators.setLocale(danish, of: device)
        #expect(try simulators.locale(of: device) == danish)

        var format = PropertyListSerialization.PropertyListFormat.xml
        let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: device.globalPreferences), format: &format)
        #expect(format == .binary)
        #expect((written as? [String: Any])?["AppleLanguagesSchemaVersion"] as? Int == 5400)
    }

    /// An iPad left in Windowed Apps draws its app's name by the clock and a
    /// resize handle in every screenshot's corner.
    @Test func anIPadsAppsAreSetFullScreenAndItsOtherSettingsKept() throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitWindowingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let device = Simulators.Device(udid: "A", name: "worker", state: "Shutdown", isAvailable: true,
                                       deviceTypeIdentifier: nil, dataPath: data.path)
        try FileManager.default.createDirectory(at: device.springBoardPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let springBoard: [String: Any] = ["SBShowBatteryPercentage": true]
        try PropertyListSerialization.data(fromPropertyList: springBoard, format: .binary, options: 0).write(to: device.springBoardPreferences)

        try Simulators().setFullScreenApps(of: device)

        let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: device.springBoardPreferences), format: nil) as? [String: Any]
        #expect(written?[Simulators.windowedAppsKey] as? Bool == false)
        #expect(written?["SBShowBatteryPercentage"] as? Bool == true)
    }

    /// The second piece starts when the first ends, and a failure passes
    /// the turn on.
    @Test func turnsRunOneAtATime() async throws {
        let turns = Turns()
        let log = Log()
        let first = Task {
            try await turns.taking {
                await log.add("first started")
                try await Task.sleep(for: .milliseconds(50))
                await log.add("first ended")
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task {
            try await turns.taking {
                await log.add("second started")
                throw CancellationError()
            }
        }
        try await first.value
        await #expect(throws: CancellationError.self) { try await second.value }
        try await turns.taking { await log.add("third started") }
        #expect(await log.lines == ["first started", "first ended", "second started", "third started"])
    }

    actor Log {
        var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
    }

    /// Seen on freshly booted clones: the launch ends with neither a process
    /// nor a reason, and the next request starts the app.
    @Test func aDroppedLaunchIsToldApartFromAFailedOne() {
        func failure(_ stderr: String) -> ShellError {
            ShellError(command: "xcrun simctl launch", status: 3, stderr: stderr, log: nil)
        }
        #expect(Simulators.isDroppedLaunch(failure("""
            An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):
            Simulator device failed to launch com.example.app.
            Underlying error (domain=NSPOSIXErrorDomain, code=3):
            	Application launch for 'com.example.app' did not return a process handle nor launch error.
            """)))
        #expect(Simulators.isDroppedLaunch(failure("""
            Simulator device failed to launch com.example.app.
            Underlying error (domain=FBSOpenApplicationServiceErrorDomain, code=3):
            	Process failed to launch.
            """)))
        #expect(!Simulators.isDroppedLaunch(failure("Simulator device failed to launch com.example.app. The app is not installed.")))
        #expect(!Simulators.isDroppedLaunch(CancellationError()))
    }

    @Test func aDeviceWithoutPreferencesIsAnError() {
        let device = Simulators.Device(udid: "A", name: "worker", state: "Shutdown", isAvailable: true,
                                       deviceTypeIdentifier: nil, dataPath: "/nonexistent/\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try Simulators().locale(of: device) }
    }
}

@Suite struct HTTPServerTests {
    @Test func readsTheThreeRangeForms() {
        #expect(HTTPServer.Response.byteRange("bytes=0-1", length: 100)! == (0, 1))
        #expect(HTTPServer.Response.byteRange("bytes=90-", length: 100)! == (90, 99))
        #expect(HTTPServer.Response.byteRange("bytes=-10", length: 100)! == (90, 99))
        #expect(HTTPServer.Response.byteRange("bytes=0-500", length: 100)! == (0, 99))
        #expect(HTTPServer.Response.byteRange("bytes=0-1,5-6", length: 100) == nil)
        #expect(HTTPServer.Response.byteRange("items=0-1", length: 100) == nil)
    }

    @Test func splitsThePathFromItsQuery() {
        let request = HTTPServer.Request(method: "GET", path: "/api/screenshots?strip=ios&locale=pt%2DBR&empty=", headers: [:],
                                         body: Data())
        #expect(request.route == "/api/screenshots")
        #expect(request.query("strip") == "ios")
        #expect(request.query("locale") == "pt-BR")
        #expect(request.query("empty") == "")
        #expect(request.query("position") == nil)
        #expect(HTTPServer.Request(method: "GET", path: "/", headers: [:], body: Data()).route == "/")
    }

    /// Serves `bytes` as one file over the loopback.
    private func serving(_ bytes: Data) async throws -> (HTTPServer, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "served-\(UUID().uuidString).bin")
        try bytes.write(to: file)
        let server = try HTTPServer { request in
            (try? .file(file, contentType: "application/octet-stream", range: request.headers["range"])) ?? .error(404, "gone")
        }
        return (server, URL(string: "http://127.0.0.1:\(try await server.start())/file")!)
    }

    private func request(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Int, Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(range, forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, data, http)
    }

    @Test func aFileIsServedWholeOrInTheRangeAskedFor() async throws {
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let (server, url) = try await serving(bytes)
        defer { server.stop() }

        let (status, whole, _) = try await request(url)
        #expect(status == 200)
        #expect(whole == bytes)

        let (partial, part, response) = try await request(url, range: "bytes=1048570-1048589")
        #expect(partial == 206)
        #expect(part == bytes[1_048_570...1_048_589])
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 1048570-1048589/3000000")

        let (unsatisfiable, _, _) = try await request(url, range: "bytes=3000000-")
        #expect(unsatisfiable == 416)
    }

    @Test func headSendsTheLengthWithoutTheBody() async throws {
        let (server, url) = try await serving(Data(count: 5000))
        defer { server.stop() }
        let (status, data, response) = try await request(url, method: "HEAD")
        #expect(status == 200)
        #expect(data.isEmpty)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "5000")
    }

    /// A player that reads the head of a file and hangs up, again and again,
    /// leaves the server answering the next request.
    @Test func aClientThatHangsUpEarlyLeavesTheServerServing() async throws {
        let bytes = Data(count: 8 << 20)
        let (server, url) = try await serving(bytes)
        defer { server.stop() }
        for _ in 0..<20 {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
            connection.start(queue: .global())
            let request = Data("GET /file HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
            let head: Data? = await withCheckedContinuation { continuation in
                connection.send(content: request, completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in continuation.resume(returning: data) }
                })
            }
            #expect(head.map { String(decoding: $0.prefix(15), as: UTF8.self) } == "HTTP/1.1 200 OK")
            connection.forceCancel()
        }
        let (status, whole, _) = try await request(url)
        #expect(status == 200)
        #expect(whole.count == bytes.count)
    }
}


@Suite struct TestRetryTests {
    /// A UI test whose app launch the simulator dropped is run again; one
    /// that failed for any other reason is not.
    @Test func onlyADroppedLaunchIsRetried() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        try "error: Simulator device failed to launch com.example.app. (Underlying Error: Launchd job spawn failed)"
            .write(to: log, atomically: true, encoding: .utf8)
        #expect(ScreenshotRunner.droppedLaunch(in: log))
        try "error: XCTAssertTrue failed".write(to: log, atomically: true, encoding: .utf8)
        #expect(!ScreenshotRunner.droppedLaunch(in: log))
        try "Simulator device failed to launch com.example.app. The app is not installed."
            .write(to: log, atomically: true, encoding: .utf8)
        #expect(!ScreenshotRunner.droppedLaunch(in: log))
        #expect(!ScreenshotRunner.droppedLaunch(in: log.appending(path: "missing")))
    }
}

@Suite struct DeviceTypeTests {
    /// A device type bundle whose capabilities list these built-in display
    /// widths, the first the main screen.
    func type(_ name: String, family: String, displays: [Int], in folder: URL) throws -> Simulators.DeviceType {
        let bundle = folder.appending(path: "\(name).simdevicetype")
        let resources = bundle.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let capabilities: [String: Any] = [
            "ScreenDimensionsCapability": ["main-screen-width": displays[0], "main-screen-height": 2000],
            "displays": displays.enumerated().map { ["displayType": "integrated", "width": $1, "height": 2000, "screenID": $0 * 2 + 1] }
                + [["displayType": "tvOut", "width": 720, "height": 480, "screenID": 2]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: ["capabilities": capabilities], format: .xml, options: 0)
        try data.write(to: resources.appending(path: "capabilities.plist"))
        return Simulators.DeviceType(identifier: name, name: name, productFamily: family, bundlePath: bundle.path)
    }

    /// A foldable's outer display has fewer pixels than a Pro Max's, and it
    /// is iPhone Duo's alone either way.
    @Test func aFoldableIPhoneIsIPhoneDuosAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let proMax = try type("Pro Max", family: "iPhone", displays: [1320], in: folder)
        let duo = try type("Duo", family: "iPhone", displays: [1398, 2007], in: folder)
        let iPad = try type("iPad", family: "iPad", displays: [2064], in: folder)
        let all = [proMax, duo, iPad]
        #expect(Simulators.types(all, for: .iPhone).map(\.name) == ["Pro Max"])
        #expect(Simulators.types(all, for: .iPhoneDuo).map(\.name) == ["Duo"])
        #expect(Simulators.types(all, for: .iPad).map(\.name) == ["iPad"])
        #expect(Simulators.pixels(duo) == 1398 * 2000)
    }

    /// The inner display is the larger built-in one, opened at its native
    /// rotation; a phone has none.
    @Test func aFoldablesInnerDisplayIsItsLargerBuiltInOne() {
        func capabilities(_ widths: [Int], rotation: Int = 270) -> [String: Any] {
            ["displays": widths.enumerated().map {
                ["displayType": "integrated", "width": $1, "height": 2853, "screenID": $0 * 2 + 1, "nativeRotation": $0 * rotation]
            } + [["displayType": "scene", "width": 7680, "height": 4320, "screenID": 9]]]
        }
        #expect(Simulators.innerDisplay(capabilities([1398, 2007])) == InnerDisplay(screenID: 3, openSize: CGSize(width: 2853, height: 2007)))
        #expect(Simulators.innerDisplay(capabilities([2007, 1398])) == InnerDisplay(screenID: 1, openSize: CGSize(width: 2007, height: 2853)))
        #expect(Simulators.innerDisplay(capabilities([1398, 2007], rotation: 180))?.openSize == CGSize(width: 2007, height: 2853))
        #expect(Simulators.innerDisplay(capabilities([1320])) == nil)
    }

    /// Folded, the inner display photographs at its unturned size: black
    /// before iOS 27.2, a spinner on black since. Only the turned size with
    /// something drawn is open.
    @Test func aFoldedInnerDisplayIsNotOpenWhateverItDraws() throws {
        let display = InnerDisplay(screenID: 3, openSize: CGSize(width: 120, height: 80))
        func frame(width: Int, height: Int, drawn: Bool) throws -> Frame {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for pixel in stride(from: 3, to: pixels.count, by: 4) { pixels[pixel] = 255 }
            if drawn {
                // A small grey mark in the middle, as the spinner is.
                for y in height / 2 - 4..<height / 2 + 4 {
                    for x in width / 2 - 4..<width / 2 + 4 { pixels.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 3, with: [200, 200, 200]) }
                }
            }
            return try Frame(image: try #require(CGImage.rgba(pixels, width: width, height: height)))
        }
        #expect(!display.showsOpen(try frame(width: 80, height: 120, drawn: false)))
        #expect(!display.showsOpen(try frame(width: 80, height: 120, drawn: true)))
        #expect(!display.showsOpen(try frame(width: 120, height: 80, drawn: false)))
        #expect(display.showsOpen(try frame(width: 120, height: 80, drawn: true)))
    }

    /// iOS 27.1 shipped for iPhone Duo alone: the other iPhones stay on the
    /// newest runtime that has them.
    @Test func eachPlatformTakesTheNewestRuntimeThatHasItsDevice() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let proMax = try type("Pro Max", family: "iPhone", displays: [1320], in: folder)
        let pro = try type("Pro", family: "iPhone", displays: [1206], in: folder)
        let duo = try type("Duo", family: "iPhone", displays: [1398, 2007], in: folder)
        func runtime(_ version: String, _ types: [Simulators.DeviceType]) -> Simulators.Runtime {
            Simulators.Runtime(identifier: version, name: "iOS \(version)", version: version, platform: "iOS",
                               isAvailable: true, supportedDeviceTypes: types)
        }
        let runtimes = [runtime("27.0", [pro, proMax]), runtime("27.1", [duo]), runtime("26.4", [pro, proMax])]
        let iPhone = try Simulators.pick(.largest, for: .iPhone, in: runtimes)
        #expect(iPhone.type.name == "Pro Max" && iPhone.runtime.version == "27.0")
        let named = try Simulators.pick(.named("Pro"), for: .iPhone, in: runtimes)
        #expect(named.type.name == "Pro" && named.runtime.version == "27.0")
        let iPhoneDuo = try Simulators.pick(.largest, for: .iPhoneDuo, in: runtimes)
        #expect(iPhoneDuo.type.name == "Duo" && iPhoneDuo.runtime.version == "27.1")
        #expect(throws: RunnerError.self) { try Simulators.pick(.largest, for: .iPhoneDuo, in: Array(runtimes.prefix(1))) }
    }
}

@Suite struct SlimServicesTests {
    /// The overrides go where `launchd_sim` reads them, every slimmed label
    /// on, and an entry the runtime wrote for itself is kept.
    @Test func overridesAreWrittenBesideTheDevicesLaunchdLog() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SlimServices.store("UDID", root: root)
        #expect(file.path.hasSuffix("com.apple.CoreSimulator.SimDevice.UDID/disabled.plist"))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.nanonewscd": false], format: .xml, options: 0).write(to: file)
        try SlimServices.write("UDID", root: root)
        let entries = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Bool])
        #expect(entries["com.apple.nanonewscd"] == false)
        #expect(SlimServices.disabled.allSatisfy { entries[$0] == true })
        #expect(entries.count == SlimServices.disabled.count + 1)
    }

    /// What an app's screens can need stays on.
    @Test func storeKitICloudAndAssetsStayOn() {
        for label in ["com.apple.storekitd", "com.apple.itunesstored", "com.apple.cloudd", "com.apple.mobileassetd",
                      "com.apple.assistantd", "com.apple.gamed", "com.apple.sharingd"] {
            #expect(!SlimServices.disabled.contains(label), "\(label)")
        }
        #expect(Set(SlimServices.disabled).count == SlimServices.disabled.count)
    }

    /// Read back from `launchctl print-disabled system`.
    @Test func aLabelTheRuntimeLeftOnIsMissing() {
        let all = SlimServices.disabled.map { "\t\t\"\($0)\" => disabled" }
        #expect(SlimServices.missing(in: "\tdisabled services = {\n" + all.joined(separator: "\n") + "\n\t}").isEmpty)
        let oneOn = all.dropFirst() + ["\t\t\"\(SlimServices.disabled[0])\" => enabled"]
        #expect(SlimServices.missing(in: oneOn.joined(separator: "\n")) == [SlimServices.disabled[0]])
    }
}
