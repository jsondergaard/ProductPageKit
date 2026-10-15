/// A screen a test puts up itself, for what the app cannot show on its own:
/// StoreKit's sheet under `SKTestSession`, the system's Home Screen, another
/// app such as Safari. The test makes a `CaptureDirector(host: .test)` whose
/// scenes include `scene`, shows it when the runner asks, and returns when
/// the runner says quit. Captures that name the same test share one run of
/// it, one scene after another.
public struct TestCapture: Hashable, Sendable {
    /// As `xcodebuild -only-testing:` takes it: `AppTests/Suite/test()`, or
    /// `AppUITests/Suite/testName` for an XCTest UI test.
    public let test: String
    /// The test's scene, and the variant it is asked for in.
    public let scene: Shot

    public init(test: String, scene: Shot) {
        self.test = test
        self.scene = scene
    }
}
