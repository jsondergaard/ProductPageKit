#if DEBUG
public import CoreGraphics
import Foundation

public enum CaptureAppearance: String, Sendable {
    case light
    case dark
}

/// How an app is started into a scene: which scene and variant to draw
/// first, where the runner listens, and the appearance and window size where
/// the app sets them itself.
///
/// A scene without a runner is a launch nobody directs, such as a UI test
/// opening the app on a fixture. An app reads it from its launch arguments.
/// A test that hosts a scene itself, such as an App Review screenshot under
/// `SKTestSession`, reads it from the environment, because `xcodebuild test`
/// passes environment variables to the test host and no arguments.
public struct CaptureLaunch: Hashable, Sendable {
    public struct Control: Hashable, Sendable {
        public var host: String
        public var port: UInt16

        public init(host: String = "127.0.0.1", port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    /// The runner's listener. Nil when nobody directs the app.
    public var control: Control?
    /// Drawn from the first frame, for what an app decides at launch.
    public var scene: String?
    /// The variant the launch is in, with or without a scene: an app that
    /// decides its data at launch reads it then.
    public var variant: String?
    /// The appearance of a Mac app, or an Apple TV app, whose simulator takes
    /// none from `simctl`.
    public var appearance: CaptureAppearance?
    /// The Mac window's content size, in points.
    public var windowSize: CGSize?

    public init(control: Control?, scene: String? = nil, variant: String? = nil, appearance: CaptureAppearance? = nil,
                windowSize: CGSize? = nil) {
        self.control = control
        self.scene = scene
        self.variant = variant
        self.appearance = appearance
        self.windowSize = windowSize
    }

    /// The scene drawn from the first frame, in the launch's variant.
    public var sceneRequest: SceneRequest? {
        scene.map { SceneRequest(scene: $0, variant: variant) }
    }

    /// `-ProductPageControl 127.0.0.1:52011 -ProductPageScene inbox …`
    public var arguments: [String] {
        values.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { [$0.key.argument, $0.value] }
    }

    /// The launch named by `arguments`, or nil when they name no scene,
    /// variant or runner.
    public init?(arguments: [String]) {
        var values: [Field: String] = [:]
        for field in Field.allCases {
            if let index = arguments.firstIndex(of: field.argument), arguments.index(after: index) < arguments.endIndex {
                values[field] = arguments[arguments.index(after: index)]
            }
        }
        self.init(values: values)
    }

    /// `PRODUCTPAGE_CONTROL=127.0.0.1:52011 …`, unprefixed. The runner adds
    /// `TEST_RUNNER_`, which `xcodebuild` strips on the way to the test host.
    public var environment: [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.variable, $0.value) })
    }

    public init?(environment: [String: String]) {
        var values: [Field: String] = [:]
        for field in Field.allCases {
            values[field] = environment[field.variable]
        }
        self.init(values: values)
    }

    /// Each setting has one spelling, used as `-ProductPage<Name>` and as
    /// `PRODUCTPAGE_<NAME>`.
    private enum Field: String, CaseIterable {
        case control = "Control"
        case scene = "Scene"
        case variant = "Variant"
        case appearance = "Appearance"
        case window = "Window"

        var argument: String { "-ProductPage\(rawValue)" }
        var variable: String { "PRODUCTPAGE_\(rawValue.uppercased())" }
    }

    private var values: [Field: String] {
        var values: [Field: String] = [:]
        values[.control] = control.map { "\($0.host):\($0.port)" }
        values[.scene] = scene
        values[.variant] = variant
        values[.appearance] = appearance?.rawValue
        values[.window] = windowSize.map { "\(Int($0.width))x\(Int($0.height))" }
        return values
    }

    private init?(values: [Field: String]) {
        control = values[.control].flatMap { value -> Control? in
            guard let colon = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: colon)...]) else { return nil }
            return Control(host: String(value[..<colon]), port: port)
        }
        guard control != nil || values[.scene] != nil || values[.variant] != nil else { return nil }
        scene = values[.scene]
        variant = values[.variant]
        appearance = values[.appearance].flatMap(CaptureAppearance.init(rawValue:))
        windowSize = values[.window].flatMap { value -> CGSize? in
            let parts = value.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        }
    }
}
#endif
