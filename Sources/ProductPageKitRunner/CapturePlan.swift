import Foundation
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
    /// Simulators per platform at once, the one that shows the screens tests
    /// put up included. Nil is what the machine has room for
    /// (`Machine.simulators`).
    public var workers: Int?
    /// Takes every capture again, where the default keeps the ones taken
    /// from the same app, device and settings.
    public var force: Bool

    public init(platforms: [Platform], locales: [StoreLocale], shots: [Shot]? = nil, workers: Int? = nil, force: Bool = false) {
        self.platforms = platforms
        self.locales = locales
        self.shots = shots
        self.workers = workers
        self.force = force
    }
}

/// What a run can ask of the Mac it runs on.
public struct Machine: Sendable {
    public var cores: Int
    /// Physical memory, in bytes.
    public var memory: UInt64

    public init(cores: Int, memory: UInt64) {
        self.cores = cores
        self.memory = memory
    }

    public static var current: Machine {
        Machine(cores: ProcessInfo.processInfo.activeProcessorCount, memory: ProcessInfo.processInfo.physicalMemory)
    }

    /// What one booted worker takes with an app running in it: about 100
    /// processes once `SlimServices` are off, 3 to 4 GB. Past one for every
    /// four cores a capture is held by the CPU, not by memory: a fourth on a
    /// 15-core Mac took longer than three.
    static let simulatorMemory: UInt64 = 4 << 30
    /// What the Mac keeps for itself and a build beside the simulators.
    static let reservedMemory: UInt64 = 8 << 30

    /// Simulators to run at once: one for every four cores and every
    /// `simulatorMemory` past `reservedMemory`, and always one.
    public var simulators: Int {
        let room = memory > Self.reservedMemory ? Int((memory - Self.reservedMemory) / Self.simulatorMemory) : 0
        return max(1, min(cores / 4, room))
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
        /// The locales captured, in the project's order.
        public let locales: [StoreLocale]
        /// Simulators at once, each taking the next locale left, the one that
        /// shows the screens tests put up included. One on a Mac, which
        /// captures the front window.
        public let workers: Int
        public let reviewScreenshots: [ReviewScreenshot]

        /// This target on `locales` alone: the ones that have something left
        /// to capture.
        func taking(_ locales: [StoreLocale]) -> Target {
            Target(platform: platform, shots: shots, components: components, primary: primary, locales: locales,
                   workers: workers, reviewScreenshots: reviewScreenshots)
        }

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
    public let force: Bool

    public init(project: Project, request: CaptureRequest, machine: Machine) throws {
        force = request.force
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
            case .simulator: max(1, min(request.workers ?? machine.simulators, request.locales.count))
            }
            return Target(platform: platform, shots: shots, components: components, primary: primary,
                          locales: request.locales, workers: workers, reviewScreenshots: reviews)
        }
        guard !targets.isEmpty else { throw RunnerError.nothingToCapture }
    }

    /// One variant's scenes, then the components it exports, in a launch of
    /// its own or in the app the step before left running.
    struct Launch: Equatable {
        var variant: String?
        var shots: [Shot]
        var components: [Component]
        /// Started fresh rather than continuing the app already running.
        var opensApp: Bool
    }

    /// The steps one locale takes. Each variant's shots and components go
    /// together, so an app that switches its data with the variant switches
    /// as seldom as it can. Each variant opens the app afresh when
    /// `variantsRelaunch`, and each scene that needs a cold launch gets one
    /// of its own; everything else continues the app running. The step
    /// holding the first shot comes first, so the first launch can name that
    /// shot before the app's `hello` has said which scenes relaunch.
    static func launches(_ shots: [Shot], components: [Component], relaunching: Set<String>,
                         variantsRelaunch: Bool) -> [Launch] {
        var launches = shots.filter { relaunching.contains($0.scene) }
            .map { Launch(variant: $0.variant, shots: [$0], components: [], opensApp: true) }
        var grouped: [Launch] = []
        func group(_ variant: String?) -> Int {
            if let index = grouped.firstIndex(where: { $0.variant == variant }) { return index }
            grouped.append(Launch(variant: variant, shots: [], components: [], opensApp: variantsRelaunch))
            return grouped.count - 1
        }
        for shot in shots where !relaunching.contains(shot.scene) { grouped[group(shot.variant)].shots.append(shot) }
        for component in components { grouped[group(component.variant)].components.append(component) }
        launches += grouped
        if let first = shots.first, let index = launches.firstIndex(where: { $0.shots.contains(first) }) {
            launches.insert(launches.remove(at: index), at: 0)
        }
        if !launches.isEmpty { launches[0].opensApp = true }
        return launches
    }

    /// What `--dry-run` prints.
    public var lines: [String] {
        targets.flatMap { target -> [String] in
            let place = switch target.platform.capture {
            case .simulator(.largest): "the largest \(Simulators.describe(target.platform.kind)) simulator"
            case .simulator(.named(let name)): name
            case .window(let size): size.map { "a \(Int($0.width)) × \(Int($0.height)) window" } ?? "a window"
            }
            let workers = target.workers == 1 ? "1 worker" : "\(target.workers) workers"
            var lines = ["\(target.platform.name): \(place), \(workers)"]
            for locale in target.locales {
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
