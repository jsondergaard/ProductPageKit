import CoreGraphics
import Foundation
import ProductPageKitControl
import Testing

@Suite struct ControlCodecTests {
    @Test func messagesAreFlatObjectsWithAType() throws {
        let apply = String(decoding: try LineCodec.encode(RunnerMessage.apply(SceneRequest(scene: "library", variant: "pro"))), as: UTF8.self)
        #expect(apply == #"{"scene":"library","type":"apply","variant":"pro"}"# + "\n")
        #expect(String(decoding: try LineCodec.encode(RunnerMessage.quit), as: UTF8.self) == #"{"type":"quit"}"# + "\n")
        let highlights = String(decoding: try LineCodec.encode(RunnerMessage.highlights(SceneRequest(scene: "inbox"))), as: UTF8.self)
        #expect(highlights == #"{"scene":"inbox","type":"highlights"}"# + "\n")
        let export = String(decoding: try LineCodec.encode(RunnerMessage.export(ComponentRequest(name: "sources", state: "1"))), as: UTF8.self)
        #expect(export == #"{"name":"sources","state":"1","type":"export"}"# + "\n")
    }

    @Test func everyRunnerMessageSurvivesTheWire() throws {
        let messages: [RunnerMessage] = [
            .apply(SceneRequest(scene: "library", variant: "pro")), .highlights(SceneRequest(scene: "inbox")),
            .export(ComponentRequest(name: "sources", variant: "pro")), .taken(ComponentRequest(name: "sources")), .quit,
        ]
        var decoder = LineDecoder<RunnerMessage>()
        #expect(try decoder.feed(try messages.map(LineCodec.encode).reduce(Data(), +)) == messages)
    }

    /// An app built against another version still says hello, so the runner
    /// can say which version it speaks.
    @Test func aHelloWithoutTheVariantPolicyDecodes() throws {
        let line = #"{"type":"hello","version":2,"pid":1,"bundleID":"com.example.app","platform":"ios","scenes":[]}"# + "\n"
        var decoder = LineDecoder<AppMessage>()
        let messages = try decoder.feed(Data(line.utf8))
        guard case .hello(let hello) = messages.first else { Issue.record("no hello"); return }
        #expect(hello.version == 2)
        #expect(!hello.variantsRelaunch)
    }

    @Test func everyAppMessageSurvivesTheWire() throws {
        let messages: [AppMessage] = [
            .hello(Hello(pid: 42, bundleID: "com.example.app", platform: .macOS,
                         scenes: [SceneDescription(name: "inbox", relaunch: false), SceneDescription(name: "panel", relaunch: true)],
                         variantsRelaunch: true)),
            .ready(Ready(SceneRequest(scene: "inbox"), window: WindowInfo(number: 7, frame: CGRect(x: 1, y: 2, width: 800, height: 600)))),
            .ready(Ready(SceneRequest(scene: "inbox", variant: "pro"), window: nil)),
            .highlights(SceneHighlights(SceneRequest(scene: "inbox"), rects: [CGRect(x: 0.1, y: 0.25, width: 0.8, height: 0.125)])),
            .failed(Failure(SceneRequest(scene: "inbox"), reason: "no fixture\nfor it")),
            .exported(ExportedComponent(ComponentRequest(name: "sources"), png: Data([0x89, 0x50, 0x4E, 0x47]))),
            .showing(ShownComponent(ComponentRequest(name: "sources", state: "1", variant: "pro"),
                                    window: WindowInfo(number: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 200)), backdrop: .white)),
            .exportFailed(ComponentFailure(ComponentRequest(name: "nothing"), reason: "no such component")),
        ]
        var decoder = LineDecoder<AppMessage>()
        let wire = try messages.map(LineCodec.encode).reduce(Data(), +)
        #expect(try decoder.feed(wire) == messages)
    }

    @Test func aLineSplitAcrossReadsWaitsForItsEnd() throws {
        let wire = try LineCodec.encode(RunnerMessage.apply(SceneRequest(scene: "inbox"))) + LineCodec.encode(RunnerMessage.quit)
        var decoder = LineDecoder<RunnerMessage>()
        #expect(try decoder.feed(wire.prefix(10)) == [])
        #expect(try decoder.feed(wire.dropFirst(10).prefix(30)) == [.apply(SceneRequest(scene: "inbox"))])
        #expect(try decoder.feed(wire.dropFirst(40)) == [.quit])
    }

    /// A component of tens of megabytes, read a little at a time, arrives in
    /// one piece and in time linear in its size.
    @Test func aLargeComponentArrivesWhole() throws {
        let png = Data((0..<24_000_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 24) })
        let message = AppMessage.exported(ExportedComponent(ComponentRequest(name: "library"), png: png))
        let wire = try LineCodec.encode(message) + LineCodec.encode(AppMessage.exportFailed(ComponentFailure(ComponentRequest(name: "x"), reason: "y")))
        var decoder = LineDecoder<AppMessage>()
        var received: [AppMessage] = []
        let started = ContinuousClock.now
        var offset = 0
        while offset < wire.count {
            received += try decoder.feed(wire[offset..<min(offset + 64 * 1024, wire.count)])
            offset += 64 * 1024
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(received.count == 2)
        #expect(received.first == message)
    }

    @Test func anUnknownMessageIsAnError() {
        var decoder = LineDecoder<RunnerMessage>()
        #expect(throws: DecodingError.self) { try decoder.feed(Data((#"{"type":"dance"}"# + "\n").utf8)) }
    }
}

@Suite struct CaptureLaunchTests {
    let launch = CaptureLaunch(control: CaptureLaunch.Control(port: 52011), scene: "library", variant: "pro", appearance: .dark,
                               windowSize: CGSize(width: 1280, height: 800))

    @Test func argumentsRoundTrip() {
        #expect(launch.arguments == [
            "-ProductPageAppearance", "dark", "-ProductPageControl", "127.0.0.1:52011", "-ProductPageScene", "library",
            "-ProductPageVariant", "pro", "-ProductPageWindow", "1280x800",
        ])
        #expect(CaptureLaunch(arguments: ["/path/App", "-AppleLanguages", "(da)"] + launch.arguments) == launch)
    }

    @Test func theEnvironmentRoundTrips() {
        #expect(launch.environment["PRODUCTPAGE_CONTROL"] == "127.0.0.1:52011")
        #expect(CaptureLaunch(environment: launch.environment.merging(["HOME": "/Users/me"]) { $1 }) == launch)
    }

    @Test func aSceneWithoutARunnerIsALaunchNobodyDirects() {
        #expect(CaptureLaunch(arguments: ["/path/App", "-ProductPageScene", "inbox"])
                == CaptureLaunch(control: nil, scene: "inbox"))
        #expect(CaptureLaunch(control: nil, scene: "library", variant: "pro").sceneRequest == SceneRequest(scene: "library", variant: "pro"))
    }

    /// An app that decides its data at launch is started in a variant before
    /// it shows any scene.
    @Test func aVariantNeedsNoScene() {
        let launch = CaptureLaunch(arguments: ["/path/App", "-ProductPageVariant", "pro"])
        #expect(launch == CaptureLaunch(control: nil, variant: "pro"))
        #expect(launch?.sceneRequest == nil)
    }

    @Test func withNeitherThereIsNoLaunch() {
        #expect(CaptureLaunch(arguments: ["/path/App", "-AppleLanguages", "(da)"]) == nil)
        #expect(CaptureLaunch(environment: ["PRODUCTPAGE_CONTROL": "nonsense"]) == nil)
    }
}
