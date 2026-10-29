/// A view the app draws on its own with nothing around it, for a theme to
/// compose into a frame: a list, a card, a row of badges. The app exports
/// it at the runner's request; see `CaptureComponents` in
/// ProductPageKitCapture.
public struct Component: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String
    /// One of the states the app can put it in, such as a row selected.
    public let state: String?
    /// The variant of the app it is drawn in, as a shot's.
    public let variant: String?

    public init(_ name: String, state: String? = nil, variant: String? = nil) {
        self.name = name
        self.state = state
        self.variant = variant
    }

    public init(stringLiteral name: String) {
        self.init(name)
    }

    /// `detail-sources@1-pro`: the name, then the state after `@` and the
    /// variant after `-`, each when it has one.
    public var fileName: String {
        name + (state.map { "@\($0)" } ?? "") + (variant.map { "-\($0)" } ?? "")
    }

    /// The component whatever its state: its states are taken together and
    /// share one frame.
    public var anyState: Component { Component(name, variant: variant) }

    public var description: String {
        var parts: [String] = []
        if let state { parts.append("state \(state)") }
        if let variant { parts.append(variant) }
        return parts.isEmpty ? name : "\(name) (\(parts.joined(separator: ", ")))"
    }
}
