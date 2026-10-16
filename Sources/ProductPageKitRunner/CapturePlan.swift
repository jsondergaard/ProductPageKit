public import ProductPageKitCore

/// What a capture run asks for: a subset of the project, or all of it.
public struct CaptureRequest: Sendable {
    public var platforms: [Platform]
    public var locales: [StoreLocale]
    /// Nil captures what each platform's frames and videos draw, the renders
    /// and the review screenshots. Otherwise exactly these, on every selected
    /// platform, and no components, renders or review screenshots: a scene
    /// outside a platform's list is captured under its name, to look at.
    public var shots: [Shot]?
    /// Simulators per platform. Nil is one for every four cores.
    public var workers: Int?

    public init(platforms: [Platform], locales: [StoreLocale], shots: [Shot]? = nil, workers: Int? = nil) {
        self.platforms = platforms
        self.locales = locales
        self.shots = shots
        self.workers = workers
    }
}

/// The run worked out from a request before anything starts: what each
/// platform captures, on how many workers, and which locales each takes.
public struct CapturePlan: Sendable {
    /// The renders a target takes, in the primary locale.
    public struct Renders: Sendable {
        public let locale: StoreLocale
        public let shots: [Shot]
        public let components: [Component]
        /// Screens tests put up, run beside the App Review screenshots.
        public let tests: [TestCapture]
    }

    public struct Target: Sendable {
        public let platform: Platform
        public let shots: [Shot]
        public let components: [Component]
        /// What is taken in the primary locale alone: the renders.
        public let primary: Renders?
        /// The locales each worker captures, in turn. One worker on a Mac,
        /// which captures the front window.
        public let workers: [[StoreLocale]]
        public let reviewScreenshots: [ReviewScreenshot]

        /// The scenes captured in `locale`.
        public func shots(in locale: StoreLocale) -> [Shot] {
            shots + (primary?.locale == locale ? primary?.shots ?? [] : [])
        }

        /// The components exported in `locale`.
        public func components(in locale: StoreLocale) -> [Component] {
            components + (primary?.locale == locale ? primary?.components ?? [] : [])
        }

        /// The files this run writes for a locale.
        public func fileNames(in locale: StoreLocale) -> [String] {
            shots(in: locale).map { platform.fileName(for: $0) + ".png" }
        }

        /// Every screen a test puts up: the App Review screenshots, then the
        /// renders'. All run in the primary locale, on a simulator of their
        /// own beside the workers, or on the Mac before its locales.
        public var tests: [TestCapture] {
            reviewScreenshots.map(\.capture) + (primary?.tests ?? [])
        }
    }

    public let targets: [Target]

    public init(project: Project, request: CaptureRequest, cores: Int) throws {
        targets = request.platforms.compactMap { platform in
            let shots = request.shots ?? project.captures(on: platform.kind)
            let components = request.shots == nil ? project.components(on: platform.kind) : []
            let reviews = request.shots == nil ? project.reviewScreenshots : []
            let renders = Renders(locale: project.primaryLocale, shots: project.renderCaptures(on: platform.kind),
                                  components: project.renderComponents(on: platform.kind), tests: project.renderTests(on: platform.kind))
            let primary = request.shots == nil && request.locales.contains(project.primaryLocale)
                && !(renders.shots.isEmpty && renders.components.isEmpty && renders.tests.isEmpty) ? renders : nil
            guard !shots.isEmpty || !components.isEmpty || primary != nil else { return nil }
            let workers: Int = switch platform.capture {
            case .window: 1
            case .simulator: max(1, min(request.workers ?? cores / 4, request.locales.count))
            }
            return Target(platform: platform, shots: shots, components: components, primary: primary,
                          workers: Self.split(request.locales, into: workers), reviewScreenshots: reviews)
        }
        guard !targets.isEmpty else { throw RunnerError.nothingToCapture }
    }

    /// Round robin, so each worker gets a share in the project's order.
    static func split(_ locales: [StoreLocale], into workers: Int) -> [[StoreLocale]] {
        (0..<workers).map { worker in locales.enumerated().filter { $0.offset % workers == worker }.map(\.element) }
            .filter { !$0.isEmpty }
    }

    /// One launch of the app in a locale: the scenes it draws, then the
    /// components it exports, all in one variant when the app decides its
    /// data from the variant at launch.
    struct Launch: Equatable {
        var variant: String?
        var shots: [Shot]
        var components: [Component]
    }

    /// The launches one locale takes. The shots and components drawn in
    /// process share one, or one per variant when `variantsRelaunch`; each
    /// scene that needs a cold launch gets its own. The launch holding the
    /// first shot comes first, so the first launch can name that shot before
    /// the app's `hello` has said which scenes relaunch.
    static func launches(_ shots: [Shot], components: [Component], relaunching: Set<String>,
                         variantsRelaunch: Bool) -> [Launch] {
        var launches = shots.filter { relaunching.contains($0.scene) }.map { Launch(variant: $0.variant, shots: [$0], components: []) }
        var grouped: [Launch] = []
        func group(_ variant: String?) -> Int {
            let key = variantsRelaunch ? variant : nil
            if let index = grouped.firstIndex(where: { $0.variant == key }) { return index }
            grouped.append(Launch(variant: key, shots: [], components: []))
            return grouped.count - 1
        }
        for shot in shots where !relaunching.contains(shot.scene) { grouped[group(shot.variant)].shots.append(shot) }
        for component in components { grouped[group(component.variant)].components.append(component) }
        launches += grouped
        if let first = shots.first, let index = launches.firstIndex(where: { $0.shots.contains(first) }) {
            launches.insert(launches.remove(at: index), at: 0)
        }
        return launches
    }

    /// What `--dry-run` prints.
    public var lines: [String] {
        targets.flatMap { target -> [String] in
            let place = switch target.platform.capture {
            case .simulator(.largest): "the largest \(Simulators.family(target.platform.kind).family) simulator"
            case .simulator(.named(let name)): name
            case .window(let size): size.map { "a \(Int($0.width)) × \(Int($0.height)) window" } ?? "a window"
            }
            let workers = target.workers.count == 1 ? "1 worker" : "\(target.workers.count) workers"
            var lines = ["\(target.platform.name): \(place), \(workers)"]
            for locale in target.workers.flatMap({ $0 }) {
                lines.append("  \(locale.code): \(target.fileNames(in: locale).joined(separator: " "))")
            }
            if !target.components.isEmpty {
                lines.append("  components in each: \(target.components.map(\.fileName).joined(separator: " "))")
            }
            if let primary = target.primary, !primary.components.isEmpty {
                lines.append("  components in \(primary.locale.code) alone: \(primary.components.map(\.fileName).joined(separator: " "))")
            }
            for review in target.reviewScreenshots {
                lines.append("  App Review screenshot of the \(review.kind.title), from \(review.test)")
            }
            if let primary = target.primary {
                for test in primary.tests { lines.append("  \(test.scene) in \(primary.locale.code), from \(test.test)") }
            }
            return lines
        }
    }
}
