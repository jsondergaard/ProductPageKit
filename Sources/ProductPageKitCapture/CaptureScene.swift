#if DEBUG
public import CoreGraphics

/// A state an app can be put in for a screenshot, named by its raw value.
///
/// An app's fixture enum conforms with nothing else to write:
///
/// ```swift
/// enum Scene: String, CaptureScene {
///     case inbox, detail, settings
/// }
/// ```
public protocol CaptureScene: RawRepresentable<String>, CaseIterable, Hashable, Sendable {
    /// How the runner reaches the scene. In process unless the app can only
    /// draw it from a cold launch, for instance because it picks a window
    /// scene at launch.
    var launchPolicy: CaptureLaunchPolicy { get }
    /// How the runner reaches another variant. In process unless the app
    /// decides its data from the variant at launch, in which case each
    /// variant's scenes and components are drawn from a launch of its own.
    static var variantPolicy: CaptureLaunchPolicy { get }
}

extension CaptureScene {
    public var launchPolicy: CaptureLaunchPolicy { .inProcess }
    public static var variantPolicy: CaptureLaunchPolicy { .inProcess }
}

public enum CaptureLaunchPolicy: Sendable {
    /// `apply` in the running app.
    case inProcess
    /// A launch of its own, with the scene named on the command line.
    case relaunch
}

/// The App Review screenshots a test draws for itself, because the screen
/// needs something only a test bundle has, such as `SKTestSession`.
/// What a test that drives the system reports once its scene is up.
public struct CaptureShown: Sendable {
    /// Parts of the screen that move on purpose, such as video playing behind
    /// a menu, as fractions of it. The runner's check for still frames leaves
    /// them out.
    public var moving: [CGRect]

    public init(moving: [CGRect] = []) {
        self.moving = moving
    }
}

public enum ReviewScene: String, CaptureScene {
    /// The subscription screen App Store Connect asks for on each in-app
    /// purchase.
    case inAppPurchases
}
#endif
