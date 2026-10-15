/// An image of the app for somewhere other than the App Store, such as the
/// app's website: a scene captured, a component exported, or a screen a test
/// puts up, on one platform. A capture run takes it in the primary locale
/// beside the store's captures, and `export` copies it out under its name.
public struct Render: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case capture(Shot, Platform.Kind)
        case component(Component, Platform.Kind)
        /// The system's screens, or another app's, which only a test reaches.
        case test(TestCapture, Platform.Kind)

        public static func capture(_ shot: Shot, on platform: Platform.Kind) -> Source {
            .capture(shot, platform)
        }

        public static func component(_ component: Component, on platform: Platform.Kind) -> Source {
            .component(component, platform)
        }

        /// `test`'s `scene`, in a variant if it has one.
        public static func test(_ test: String, scene: Shot, on platform: Platform.Kind) -> Source {
            .test(TestCapture(test: test, scene: scene), platform)
        }

        public var platform: Platform.Kind {
            switch self {
            case .capture(_, let platform), .component(_, let platform), .test(_, let platform): platform
            }
        }
    }

    /// The file it is copied to, without `.png`.
    public let name: String
    public let source: Source

    public init(_ name: String, _ source: Source) {
        self.name = name
        self.source = source
    }
}
