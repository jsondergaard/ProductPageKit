import Foundation

/// An ordered list of screenshots: a platform's own, a custom page's, or an
/// experiment treatment's. A theme is told which one a frame belongs to, and
/// may lay out a treatment's shots differently from the store's.
public enum ShotList: Hashable, Codable, Sendable {
    case store
    /// By the page's key.
    case customPage(String)
    /// By the treatment's key.
    case treatment(String)

    /// The caption a shot of this list shows when it has one of its own.
    func captionSubject(_ shot: Shot) -> CaptionSubject {
        switch self {
        case .store: .screenshot(shot)
        case .customPage(let key): .pageScreenshot(key, shot)
        case .treatment(let key): .treatmentScreenshot(key, shot)
        }
    }

    /// The folder beside a platform's own screenshots that holds this list's,
    /// or nil for the platform's own.
    public var folder: String? {
        switch self {
        case .store: nil
        case .customPage(let key): "page-\(key)"
        case .treatment(let key): "treatment-\(key)"
        }
    }

    /// ` of the pro page`: what follows the description of one of its
    /// screenshots, nothing for the platform's own.
    var qualifier: String {
        switch self {
        case .store: ""
        case .customPage(let key): " of the \(key) page"
        case .treatment(let key): " of the \(key) treatment"
        }
    }
}

/// What a platform, a custom page and a treatment share: shots in order,
/// each with a caption and a file name.
public protocol ShotListing: Sendable {
    var list: ShotList { get }
    var shots: [Shot] { get }
    /// Shots that show the store's caption, on purpose, rather than one
    /// written for this list.
    var storeCaptions: [Shot] { get }
}

extension ShotListing {
    /// The caption a shot shows: this list's own, or the store's.
    public func captionSubject(_ shot: Shot) -> CaptionSubject {
        storeCaptions.contains(shot) ? .screenshot(shot) : list.captionSubject(shot)
    }

    /// The shots with a caption of their own.
    var captionedShots: [Shot] { shots.filter { !storeCaptions.contains($0) } }

    /// `01_inbox`: the shot's place in the list, then its name. A shot not in
    /// the list, such as a scene captured to look at, keeps its name alone and
    /// is never framed or uploaded.
    public func fileName(for shot: Shot) -> String {
        guard let index = shots.firstIndex(of: shot) else { return shot.name }
        return String(format: "%02d_%@", index + 1, shot.name)
    }

    /// Too many shots, and a shot listed twice, for `owner` to be named in.
    func shotProblems(owner: String) -> [String] {
        var problems: [String] = []
        if shots.count > Platform.maximumShots {
            problems.append("\(owner) lists \(shots.count) shots, and App Store Connect takes \(Platform.maximumShots)")
        }
        for shot in shots.repeated {
            problems.append("\(owner) lists \(shot) twice")
        }
        return problems
    }

    /// Problems with a page's or treatment's key, name and shots, for `owner`
    /// to be named in: `the pro page`.
    func problems(owner: String, key: String, name: String, storeShots: Set<Shot>) -> [String] {
        var problems = shotProblems(owner: owner)
        if !key.isCatalogKey { problems.append("\(owner)'s key must be letters, digits and hyphens") }
        if name.isEmpty { problems.append("\(owner) has no name") }
        if shots.isEmpty { problems.append("\(owner) has no shots") }
        for shot in storeCaptions {
            if !shots.contains(shot) {
                problems.append("\(owner) gives \(shot) the store's caption, and does not list it")
            } else if !storeShots.contains(shot) {
                problems.append("\(owner) gives \(shot) the store's caption, and no platform's list has \(shot)")
            }
        }
        return problems
    }
}

extension Platform: ShotListing {
    public var list: ShotList { .store }
    /// The platform's list is the store's own, so it borrows nothing.
    public var storeCaptions: [Shot] { [] }
}

extension Platform.Kind {
    /// The platforms App Store Connect takes screenshots of a custom page and
    /// of an experiment treatment for.
    public static let alternateScreenshotPlatforms: [Platform.Kind] = [.iPhone, .iPad]
}

extension String {
    /// Whether this can be a custom page's, experiment's or treatment's key:
    /// it is a part of a catalog key and of a file name.
    var isCatalogKey: Bool {
        !isEmpty && allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
