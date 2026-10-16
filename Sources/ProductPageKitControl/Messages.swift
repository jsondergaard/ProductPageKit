#if DEBUG
public import CoreGraphics
public import Foundation

/// The control protocol between an app under capture and the runner: one JSON
/// object per line, over a loopback TCP connection the runner listens on.
///
/// The app says `hello` when it connects. The runner then sends `apply` for
/// each scene it wants, and the app answers `ready` once the scene is on
/// screen, or `failed`. Until then it says what the scene is `waiting` for
/// whenever that changes, and the runner brings an app that is not in front
/// forward. Once the runner has photographed the scene it asks for its
/// `highlights`, measured as they were photographed.
///
/// The runner sends `export` for each component it wants. On a simulator the
/// app draws it in process and answers `exported` with the image. On a Mac,
/// where only the window server draws glass, it shows the component in a
/// window over black and answers `showing`; the runner photographs it and
/// says `taken`; then the same over white, and the runner derives the
/// transparent component from the pair. `exportFailed` answers either.
///
/// `quit` ends the session.
public enum ControlProtocol {
    /// Raised when a message changes shape. The runner refuses an app built
    /// against another version, which would otherwise decode as nonsense.
    public static let version = 4
}

/// A scene, and the variant it is shown with.
public struct SceneRequest: Codable, Hashable, Sendable, CustomStringConvertible {
    public var scene: String
    public var variant: String?

    public init(scene: String, variant: String? = nil) {
        self.scene = scene
        self.variant = variant
    }

    public var description: String { variant.map { "\(scene) (\($0))" } ?? scene }
}

/// One of the app's scenes, as `hello` lists it.
public struct SceneDescription: Codable, Hashable, Sendable {
    public var name: String
    /// The scene needs a cold launch rather than `apply` in a running app.
    public var relaunch: Bool

    public init(name: String, relaunch: Bool) {
        self.name = name
        self.relaunch = relaunch
    }
}

public enum ControlPlatform: String, Codable, Sendable {
    case iOS = "ios"
    case tvOS = "tvos"
    case macOS = "macos"

    public static var current: ControlPlatform {
        #if os(macOS)
        .macOS
        #elseif os(tvOS)
        .tvOS
        #else
        .iOS
        #endif
    }
}

public struct Hello: Codable, Hashable, Sendable {
    public var version: Int
    public var pid: Int32
    public var bundleID: String
    public var platform: ControlPlatform
    public var scenes: [SceneDescription]
    /// The app decides its data from the variant at launch, so each variant
    /// is drawn from a launch of its own.
    public var variantsRelaunch: Bool

    public init(version: Int = ControlProtocol.version, pid: Int32, bundleID: String, platform: ControlPlatform,
                scenes: [SceneDescription], variantsRelaunch: Bool) {
        self.version = version
        self.pid = pid
        self.bundleID = bundleID
        self.platform = platform
        self.scenes = scenes
        self.variantsRelaunch = variantsRelaunch
    }

    private enum CodingKeys: String, CodingKey { case version, pid, bundleID, platform, scenes, variantsRelaunch }

    /// An app of another protocol version may lack a field this one has;
    /// decoding what it sent lets the runner say which version it speaks.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        pid = try container.decode(Int32.self, forKey: .pid)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        platform = try container.decode(ControlPlatform.self, forKey: .platform)
        scenes = try container.decode([SceneDescription].self, forKey: .scenes)
        variantsRelaunch = try container.decodeIfPresent(Bool.self, forKey: .variantsRelaunch) ?? false
    }
}

/// The Mac window a scene is drawn in, which the runner photographs by number.
public struct WindowInfo: Codable, Hashable, Sendable {
    public var number: Int
    /// In screen points.
    public var frame: CGRect

    public init(number: Int, frame: CGRect) {
        self.number = number
        self.frame = frame
    }
}

public struct Ready: Codable, Hashable, Sendable {
    public var scene: String
    public var variant: String?
    /// On a Mac only.
    public var window: WindowInfo?
    /// Views that move on purpose, such as a video playing, which the frame
    /// check leaves out: fractions of the screen or window, from its top left.
    public var moving: [CGRect]

    public init(_ request: SceneRequest, window: WindowInfo?, moving: [CGRect] = []) {
        scene = request.scene
        variant = request.variant
        self.window = window
        self.moving = moving
    }

    public var request: SceneRequest { SceneRequest(scene: scene, variant: variant) }
}

/// What a scene asked for waits on before it is ready.
public struct Waiting: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable, CustomStringConvertible {
        /// The views drawn for the scene, after `apply` replaced the last one's.
        case views
        /// A `.captureReady` condition that does not hold yet.
        case conditions
        /// The scene to become active: the app is not in front.
        case activeScene
        /// On a Mac, the window to become key: another app is in front.
        case keyWindow

        /// Whether bringing the app to the front is what it waits for.
        public var needsFront: Bool { self == .activeScene || self == .keyWindow }

        public var description: String {
            switch self {
            case .views: "its views to be drawn"
            case .conditions: "its `.captureReady` conditions to hold"
            case .activeScene: "its scene to become active"
            case .keyWindow: "its window to become key"
            }
        }
    }

    public var scene: String
    public var variant: String?
    public var reasons: [Reason]

    public init(_ request: SceneRequest, reasons: [Reason]) {
        scene = request.scene
        variant = request.variant
        self.reasons = reasons
    }

    public var request: SceneRequest { SceneRequest(scene: scene, variant: variant) }
}

/// Where a scene's views marked with `.captureHighlight()` are.
public struct SceneHighlights: Codable, Hashable, Sendable {
    public var scene: String
    public var variant: String?
    /// Fractions of the screen or window photographed, from its top left,
    /// top to bottom.
    public var rects: [CGRect]

    public init(_ request: SceneRequest, rects: [CGRect]) {
        scene = request.scene
        variant = request.variant
        self.rects = rects
    }

    public var request: SceneRequest { SceneRequest(scene: scene, variant: variant) }
}

public struct Failure: Codable, Hashable, Sendable {
    public var scene: String
    public var variant: String?
    public var reason: String

    public init(_ request: SceneRequest, reason: String) {
        scene = request.scene
        variant = request.variant
        self.reason = reason
    }

    public var request: SceneRequest { SceneRequest(scene: scene, variant: variant) }
}

/// A component, in one of its states and in a variant of the app.
public struct ComponentRequest: Codable, Hashable, Sendable, CustomStringConvertible {
    public var name: String
    public var state: String?
    public var variant: String?

    public init(name: String, state: String? = nil, variant: String? = nil) {
        self.name = name
        self.state = state
        self.variant = variant
    }

    public var description: String {
        let parts = [state.map { "state \($0)" }, variant].compactMap(\.self)
        return parts.isEmpty ? name : "\(name) (\(parts.joined(separator: ", ")))"
    }
}

/// A component drawn in process, as a PNG with nothing around it.
public struct ExportedComponent: Codable, Hashable, Sendable {
    public var component: ComponentRequest
    public var png: Data

    public init(_ component: ComponentRequest, png: Data) {
        self.component = component
        self.png = png
    }
}

/// A component on a Mac, shown in a window of its own over a backdrop.
public struct ShownComponent: Codable, Hashable, Sendable {
    public enum Backdrop: String, Codable, Sendable { case black, white }

    public var component: ComponentRequest
    public var window: WindowInfo
    public var backdrop: Backdrop

    public init(_ component: ComponentRequest, window: WindowInfo, backdrop: Backdrop) {
        self.component = component
        self.window = window
        self.backdrop = backdrop
    }
}

public struct ComponentFailure: Codable, Hashable, Sendable {
    public var component: ComponentRequest
    public var reason: String

    public init(_ component: ComponentRequest, reason: String) {
        self.component = component
        self.reason = reason
    }
}

/// What the app sends.
public enum AppMessage: Hashable, Sendable {
    case hello(Hello)
    case ready(Ready)
    case waiting(Waiting)
    case highlights(SceneHighlights)
    case failed(Failure)
    case exported(ExportedComponent)
    case showing(ShownComponent)
    case exportFailed(ComponentFailure)
}

/// What the runner sends.
public enum RunnerMessage: Hashable, Sendable {
    case apply(SceneRequest)
    /// Where the scene on screen's highlights are now.
    case highlights(SceneRequest)
    case export(ComponentRequest)
    /// The component on show has been photographed over its backdrop.
    case taken(ComponentRequest)
    case quit
}

/// Both directions are flat objects with a `type` beside the payload's fields:
/// `{"type":"apply","scene":"inbox"}`.
private enum TypeKey: String, CodingKey { case type }

extension AppMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "ready": self = .ready(try Ready(from: decoder))
        case "waiting": self = .waiting(try Waiting(from: decoder))
        case "highlights": self = .highlights(try SceneHighlights(from: decoder))
        case "failed": self = .failed(try Failure(from: decoder))
        case "exported": self = .exported(try ExportedComponent(from: decoder))
        case "showing": self = .showing(try ShownComponent(from: decoder))
        case "exportFailed": self = .exportFailed(try ComponentFailure(from: decoder))
        default: throw DecodingError.dataCorrupted(.init(codingPath: [TypeKey.type], debugDescription: "unknown message \(type)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .hello(let hello):
            try container.encode("hello", forKey: .type)
            try hello.encode(to: encoder)
        case .ready(let ready):
            try container.encode("ready", forKey: .type)
            try ready.encode(to: encoder)
        case .waiting(let waiting):
            try container.encode("waiting", forKey: .type)
            try waiting.encode(to: encoder)
        case .highlights(let highlights):
            try container.encode("highlights", forKey: .type)
            try highlights.encode(to: encoder)
        case .failed(let failure):
            try container.encode("failed", forKey: .type)
            try failure.encode(to: encoder)
        case .exported(let exported):
            try container.encode("exported", forKey: .type)
            try exported.encode(to: encoder)
        case .showing(let shown):
            try container.encode("showing", forKey: .type)
            try shown.encode(to: encoder)
        case .exportFailed(let failure):
            try container.encode("exportFailed", forKey: .type)
            try failure.encode(to: encoder)
        }
    }
}

extension RunnerMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "apply": self = .apply(try SceneRequest(from: decoder))
        case "highlights": self = .highlights(try SceneRequest(from: decoder))
        case "export": self = .export(try ComponentRequest(from: decoder))
        case "taken": self = .taken(try ComponentRequest(from: decoder))
        case "quit": self = .quit
        default: throw DecodingError.dataCorrupted(.init(codingPath: [TypeKey.type], debugDescription: "unknown message \(type)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .apply(let request):
            try container.encode("apply", forKey: .type)
            try request.encode(to: encoder)
        case .highlights(let request):
            try container.encode("highlights", forKey: .type)
            try request.encode(to: encoder)
        case .export(let request):
            try container.encode("export", forKey: .type)
            try request.encode(to: encoder)
        case .taken(let request):
            try container.encode("taken", forKey: .type)
            try request.encode(to: encoder)
        case .quit:
            try container.encode("quit", forKey: .type)
        }
    }
}

/// Newline-delimited JSON. JSON escapes newlines inside strings, so a line is
/// always exactly one message.
public enum LineCodec {
    public static func encode(_ message: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message) + Data([newline])
    }

    static let newline = UInt8(ascii: "\n")
}

/// Splits a byte stream into messages, keeping a partial line for the next
/// read. Only the bytes a read adds are searched for the end of the line, so
/// a component's tens of megabytes arrive in time linear in their size.
public struct LineDecoder<Message: Decodable>: Sendable {
    /// Always starts at index 0, and holds no newline before what the last
    /// read added.
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) throws -> [Message] {
        var searched = buffer.count
        buffer.append(data)
        var messages: [Message] = []
        var start = 0
        while let end = buffer[searched...].firstIndex(of: LineCodec.newline) {
            if end > start { messages.append(try JSONDecoder().decode(Message.self, from: buffer[start..<end])) }
            start = end + 1
            searched = start
        }
        if start > 0 { buffer = Data(buffer[start...]) }
        return messages
    }
}

/// What one read from a control connection may return: large enough that a
/// component's image takes a few hundred reads rather than thousands.
public let lineReadSize = 1 << 20
#endif
