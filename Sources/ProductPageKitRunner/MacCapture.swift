import AppKit
import CoreGraphics
import Foundation
import ProductPageKitCore
import ScreenCaptureKit

/// Launching the Mac app and photographing its window.
enum MacCapture {
    /// Connects to the window server, which a command-line process has not
    /// done, and checks Screen Recording permission: without it a window
    /// capture is black, so the run stops first and says where to grant it.
    static func prepare() async throws {
        await MainActor.run { _ = NSApplication.shared }
        guard CGPreflightScreenCaptureAccess() else { throw RunnerError.noScreenRecording }
        guard !isScreenLocked else { throw RunnerError.screenLocked }
    }

    /// No app can come to the front, and no window be captured, behind the
    /// lock screen.
    static var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /// How many times a launch refused by the system is tried.
    static let launchAttempts = 5

    /// A new instance through Launch Services, so it comes up in front.
    ///
    /// Quitting and launching the app in quick succession can leave macOS
    /// refusing a launch with a "prevent launch" assertion for a moment, so a
    /// refused launch is tried again after a pause that grows with each try.
    static func launch(_ app: URL, arguments: [String]) async throws -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        for attempt in 1..<launchAttempts {
            do {
                return try await NSWorkspace.shared.openApplication(at: app, configuration: configuration).processIdentifier
            } catch let error as NSError where isLaunchRefused(error) {
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
        return try await NSWorkspace.shared.openApplication(at: app, configuration: configuration).processIdentifier
    }

    /// Whether Launch Services refused the launch because RunningBoard holds
    /// a "prevent launch" assertion for the app, which passes.
    static func isLaunchRefused(_ error: NSError) -> Bool {
        error.domain == "RBSRequestErrorDomain"
            || (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isLaunchRefused) == true
    }

    /// Brings the running instance of `app` to the front. Through `open`:
    /// macOS refuses the same request from `NSWorkspace` or
    /// `NSRunningApplication` in a process with no window of its own.
    static func activate(_ app: URL) async throws {
        _ = try await Shell.run("/usr/bin/open", [app.path])
    }

    /// Captures the window by number, at the display's scale, without its
    /// shadow or the cursor.
    ///
    /// The window is looked up again for every frame, so each one is taken
    /// at the window's size at that moment. A window still settling its size
    /// then fails the frame check instead of being scaled into a stale one.
    static func frame(ofWindow number: Int) async throws -> Frame {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { Int($0.windowID) == number }) else {
            throw RunnerError.windowNotFound(number)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return try Frame(image: try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
    }
}
