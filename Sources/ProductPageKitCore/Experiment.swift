/// A product page optimization test: up to three treatments, each with its
/// own screenshots, shown against the live product page, which is the
/// control. App Store Connect takes iPhone and iPad screenshots for one, and
/// nothing for a Mac or an Apple TV.
///
/// The project only prepares it. Starting a test, and submitting it to App
/// Review, stay in App Store Connect.
public struct Experiment: Sendable {
    /// The command line's name for it.
    public let key: String
    /// App Store Connect's name for it, which customers never see.
    public let name: String
    /// The percent of the people who visit the product page that see a
    /// treatment rather than the control, shared evenly between the
    /// treatments.
    public let trafficProportion: Int
    public let treatments: [Treatment]

    public init(_ key: String, name: String, trafficProportion: Int, treatments: [Treatment]) {
        self.key = key
        self.name = name
        self.trafficProportion = trafficProportion
        self.treatments = treatments
    }

    /// What App Store Connect takes in one test.
    public static let maximumTreatments = 3

    /// The percent of visitors a test can show a treatment to.
    static let trafficProportions = 1...100

    func problems(platforms: [Platform], storeShots: Set<Shot>) -> [String] {
        var problems: [String] = []
        let experiment = "the \(key) experiment"
        if !key.isCatalogKey { problems.append("\(experiment)'s key must be letters, digits and hyphens") }
        if name.isEmpty { problems.append("\(experiment) has no name") }
        if !Self.trafficProportions.contains(trafficProportion) {
            problems.append("\(experiment) shows treatments to \(trafficProportion) percent of visitors, and the share runs from \(Self.trafficProportions.lowerBound) to \(Self.trafficProportions.upperBound)")
        }
        if treatments.isEmpty { problems.append("\(experiment) has no treatments") }
        if treatments.count > Self.maximumTreatments {
            problems.append("\(experiment) has \(treatments.count) treatments, and App Store Connect takes \(Self.maximumTreatments)")
        }
        let names = treatments.map(\.name)
        for name in names.repeated {
            problems.append("\(experiment) has two treatments named \(name)")
        }
        if !platforms.contains(where: { Platform.Kind.alternateScreenshotPlatforms.contains($0.kind) }) {
            problems.append("\(experiment) shows screenshots on iPhone and iPad, and the project configures neither")
        }
        return problems + treatments.flatMap { $0.problems(storeShots: storeShots) }
    }
}

/// One variant of the product page's screenshots in an experiment, on every
/// locale and on each of iPhone and iPad the project configures. A treatment
/// that leaves one undefined shows the control there, while the visitors it
/// is shown to still count in its share of the test.
///
/// Its captions are in the String Catalog under
/// `treatment.<key>.screenshot.<shot>.`, as the store's screenshots have
/// under `screenshot.<shot>.`.
public struct Treatment: ShotListing {
    /// The catalog's name for it. It is unique in the project, so a theme
    /// told `ShotList.treatment(key)` knows the treatment and no other.
    public let key: String
    /// App Store Connect's name for it, which customers never see.
    public let name: String
    /// In page order.
    public let shots: [Shot]
    /// Shots that show the store's caption, on purpose, rather than one
    /// written for the treatment.
    public let storeCaptions: [Shot]

    public init(_ key: String, name: String, shots: [Shot], storeCaptions: [Shot] = []) {
        self.key = key
        self.name = name
        self.shots = shots
        self.storeCaptions = storeCaptions
    }

    public var list: ShotList { .treatment(key) }

    static func keyPrefix(_ key: String) -> String { "treatment.\(key)." }

    func problems(storeShots: Set<Shot>) -> [String] {
        problems(owner: "the \(key) treatment", key: key, name: name, storeShots: storeShots)
    }
}
