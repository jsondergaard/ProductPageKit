public import Foundation

public enum RunnerError: Error, CustomStringConvertible {
    case noXcodeProject
    case nothingToCapture
    case lock(String, String)
    case busy(String, holder: Int32?)
    case power(Int32)
    case noScreenRecording
    case screenLocked
    case noRuntime(String)
    case noDeviceType(String, runtime: String, available: [String])
    case noApp(String, String)
    case noDevice(String)
    case unreadablePreferences(String)
    case unexpectedOutput(String, String)
    case appExited(String, before: String)
    case timedOut(String)
    case sceneFailed(String, String)
    case appMismatch([String])
    case noWindow(String)
    case windowNotFound(Int)
    case unreadableCapture
    case unstable(String, frames: Int)
    case testDidNotConnect(String, log: URL)
    case componentFailed(String, String)
    case componentWindowOffMac(String)
    case mismatchedBackdrops(String)

    public var description: String {
        switch self {
        case .noXcodeProject:
            "The project has no Xcode project to capture from (Project.xcode)."
        case .nothingToCapture:
            "Nothing to capture: no frame or video on the selected platforms draws a capture or a component."
        case .lock(let path, let reason):
            "Could not lock \(path): \(reason)"
        case .busy(let purpose, let holder):
            "Another \(purpose) is running" + (holder.map { " (pid \($0))" } ?? "") + "."
        case .power(let result):
            "Could not keep the display awake (IOKit error \(result))."
        case .noScreenRecording:
            """
            Screen Recording is not allowed for this terminal, and Mac captures would come out black. \
            Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then run again.
            """
        case .screenLocked:
            "The screen is locked, so the Mac app cannot come to the front or be captured. Unlock it and run again."
        case .noRuntime(let os):
            "No \(os) simulator runtime is installed. Add one in Xcode › Settings › Components."
        case .noDeviceType(let name, let runtime, let available):
            "\(runtime) has no simulator for \(name)." + (available.isEmpty ? "" : " It has \(available.joined(separator: ", ")).")
        case .noApp(let bundleID, let folder):
            "The build has no app with the bundle id \(bundleID) in \(folder)."
        case .noDevice(let udid):
            "simctl lists no device \(udid)."
        case .unreadablePreferences(let path):
            "\(path) is not a preferences dictionary."
        case .unexpectedOutput(let command, let output):
            "Could not read what `\(command)` printed: \(output)"
        case .appExited(let app, let before):
            "\(app) ended before \(before)."
        case .timedOut(let what):
            "Gave up waiting for \(what)."
        case .sceneFailed(let request, let reason):
            "The app could not show \(request): \(reason)"
        case .appMismatch(let problems):
            "The app does not match the project:\n" + problems.map { "  \($0)" }.joined(separator: "\n")
        case .noWindow(let request):
            "The app said \(request) was ready without naming its window."
        case .windowNotFound(let number):
            "Window \(number) is not on screen."
        case .unreadableCapture:
            "A capture could not be read as an image."
        case .unstable(let what, let frames):
            "\(what) was still changing after \(frames) frames. Hold `.captureReady` false until it settles."
        case .testDidNotConnect(let test, let log):
            "The test \(test) finished without connecting. Run it only when `CaptureHost.test.isControlled`, and give it a `CaptureDirector(host: .test)`. Its output is in \(log.path)"
        case .componentFailed(let component, let reason):
            "The app could not export the component \(component): \(reason)"
        case .componentWindowOffMac(let component):
            "The app showed the component \(component) in a window, which only a Mac app does."
        case .mismatchedBackdrops(let component):
            "The component \(component) came out a different size over black and over white."
        }
    }
}
