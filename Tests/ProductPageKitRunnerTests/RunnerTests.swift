import CoreGraphics
import Foundation
import Network
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

@Suite struct LockTests {
    @Test func aSecondRunIsRefusedUntilTheFirstReleases() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitLockTests-\(UUID().uuidString)/ios.lock")
        let first = try Lock(file, purpose: "capture")
        #expect(throws: RunnerError.self) { try Lock(file, purpose: "capture") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "\(getpid())\n")
        first.release()
        try Lock(file, purpose: "capture").release()
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
        await mailbox.post(.closed)
        await mailbox.post(.exited)
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

    @Test func helloThenEachSceneThenQuit() async throws {
        let listener = try await ControlListener.start()
        defer { listener.stop() }
        let mailbox = Mailbox()
        listener.expect(mailbox)
        let app = FakeApp(port: listener.port)
        let hello = Hello(pid: getpid(), bundleID: "com.example.app", platform: .iOS,
                          scenes: [SceneDescription(name: "inbox", relaunch: false), SceneDescription(name: "broken", relaunch: false)],
                          variantsRelaunch: false)
        try app.send(.hello(hello))
        let session = try await AppSession(mailbox: mailbox, pid: getpid(), describedAs: "the fake app")
        #expect(session.hello == hello)

        let inbox = SceneRequest(scene: "inbox")
        async let ready = session.show(inbox)
        #expect(try await app.next() == .apply(inbox))
        // A stale answer for another scene is not this one's.
        try app.send(.ready(Ready(SceneRequest(scene: "other"), window: nil)))
        try app.send(.ready(Ready(inbox, window: nil)))
        #expect(try await ready.request == inbox)

        // Measured once photographed.
        async let highlights = session.highlights(of: inbox)
        #expect(try await app.next() == .highlights(inbox))
        let row = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1)
        try app.send(.highlights(SceneHighlights(inbox, rects: [row])))
        #expect(try await highlights == [row])

        let broken = SceneRequest(scene: "broken")
        let failure = Task { try await session.show(broken) }
        #expect(try await app.next() == .apply(broken))
        try app.send(.failed(Failure(broken, reason: "no fixture")))
        await #expect(throws: RunnerError.self) { try await failure.value }

        async let quit = session.quit()
        #expect(try await app.next() == .quit)
        app.connection.cancel()
        #expect(await quit)
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
        let session = try await AppSession(mailbox: mailbox, pid: getpid(), describedAs: "the fake app")
        let tile = FrameStabilityTests().image(marked: 0)

        let drawn = ComponentRequest(name: "sources")
        async let exported = session.export(drawn) { _ in throw RunnerError.componentWindowOffMac("sources") }
        #expect(try await app.next() == .export(drawn))
        try app.send(.exported(ExportedComponent(drawn, png: try Frame(image: tile).png)))
        #expect(try await exported.width == 100)

        let shown = ComponentRequest(name: "card", state: "1")
        let window = WindowInfo(number: 7, frame: CGRect(x: 0, y: 0, width: 2, height: 1))
        let photographs = Photographs(black: try Frame(image: Self.pixels([0, 0, 0, 255, 200, 0, 0, 255])),
                                      white: try Frame(image: Self.pixels([255, 255, 255, 255, 200, 0, 0, 255])))
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

    actor Photographs {
        var frames: [Frame]
        init(black: Frame, white: Frame) { frames = [black, white] }
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
    @Test func trimmingKeepsWhatIsDrawn() {
        var bytes = [UInt8](repeating: 0, count: 5 * 4 * 4)
        for index in [6, 7, 11] { bytes.replaceSubrange(index * 4..<index * 4 + 4, with: [255, 255, 255, 255]) }
        let trimmed = CGImage.rgba(bytes, width: 5, height: 4)!.trimmingTransparentEdges()
        #expect(trimmed.width == 2)
        #expect(trimmed.height == 2)
        let clear = CGImage.rgba([UInt8](repeating: 0, count: 16), width: 2, height: 2)!
        #expect(clear.trimmingTransparentEdges().width == 2)
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
