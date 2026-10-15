import Foundation
import ProductPageKitCore

/// `xcodebuild` for one project, every platform into one DerivedData.
///
/// Debug and signed: skipping signing also skips the entitlements, and an app
/// launched without its `aps-environment` or network entitlement is not the
/// app being photographed.
struct XcodeBuild: Sendable {
    let xcode: XcodeProject
    let root: URL
    let cache: Cache
    let bundleID: String

    /// Builds the app, and the tests too when the run takes screens tests put
    /// up, and returns the app bundle.
    ///
    /// A plain build comes first even then: from a clean DerivedData,
    /// `build-for-testing` alone can compile a package's copy for the test
    /// bundle before the package's build plugin has written its sources.
    func build(_ platform: Platform, destination: String, forTesting: Bool) async throws -> URL {
        let actions = forTesting ? ["build", "build-for-testing"] : ["build"]
        _ = try await Shell.run("/usr/bin/xcrun", ["xcodebuild"] + actions + arguments(destination: destination),
                                in: root, log: cache.logs.appending(path: "\(platform.id)-build.log"),
                                describedAs: "xcodebuild \(actions.joined(separator: " ")) for \(platform.name)")
        return try app(platform)
    }

    /// Runs one test from the last `build-for-testing`, with `environment`
    /// passed to the test host.
    func test(_ test: String, platform: Platform, destination: String, environment: [String: String],
              log: URL) async throws {
        // `xcodebuild` hands `TEST_RUNNER_<name>` to the test host as `<name>`.
        let passed = Dictionary(uniqueKeysWithValues: environment.map { ("TEST_RUNNER_\($0.key)", $0.value) })
        _ = try await Shell.run("/usr/bin/xcrun", ["xcodebuild", "test-without-building", "-only-testing:\(test)"]
                                    + arguments(destination: destination),
                                in: root, environment: passed, log: log, describedAs: "the test \(test)")
    }

    private func arguments(destination: String) -> [String] {
        let container: [String] = switch xcode.container {
        case .project(let path): ["-project", path]
        case .workspace(let path): ["-workspace", path]
        }
        return container + [
            "-scheme", xcode.scheme,
            "-configuration", "Debug",
            "-destination", destination,
            "-derivedDataPath", cache.derivedData.path,
            "-skipPackagePluginValidation", "-skipMacroValidation", "-allowProvisioningUpdates",
        ]
    }

    /// The app in the platform's products folder whose bundle id is the
    /// project's: the scheme may build extensions and test hosts beside it.
    func app(_ platform: Platform) throws -> URL {
        let folder = cache.derivedData.appending(path: "Build/Products/\(Self.productsFolder(platform.kind))")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for app in candidates where app.pathExtension == "app" {
            let info = platform.kind == .mac ? "Contents/Info.plist" : "Info.plist"
            if let plist = NSDictionary(contentsOf: app.appending(path: info)),
               plist["CFBundleIdentifier"] as? String == bundleID {
                return app
            }
        }
        throw RunnerError.noApp(bundleID, folder.path)
    }

    static func productsFolder(_ kind: Platform.Kind) -> String {
        switch kind {
        case .iPhone, .iPad: "Debug-iphonesimulator"
        case .appleTV: "Debug-appletvsimulator"
        case .mac: "Debug"
        }
    }
}
