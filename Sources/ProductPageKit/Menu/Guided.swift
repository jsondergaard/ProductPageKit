import ArgumentParser
import Foundation

/// A command the menu can run: it asks what its command line would say and
/// answers with those arguments, so the menu runs exactly what typing them
/// would.
protocol Guided: ParsableCommand {
    /// Whether the project has what the command works on. The menu leaves
    /// out a command that would only fail.
    static func isAvailable(in project: Project) -> Bool
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String]
}

extension Guided {
    static func isAvailable(in project: Project) -> Bool { true }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] { [] }
}

// MARK: - Questions shared by commands

extension Prompter {
    /// The platforms ticked, all to start with, and `--platforms` naming
    /// them unless all are. Nothing is asked of a project with one.
    func platforms(_ platforms: [Platform]) throws(MenuExit) -> (chosen: [Platform], arguments: [String]) {
        try subset("Which platforms?", flag: "--platforms", platforms, key: \.id, detail: \.name)
    }

    func locales(_ locales: [StoreLocale]) throws(MenuExit) -> [String] {
        try subset("Which locales?", flag: "--locales", locales, key: \.code) { locale in
            Locale.current.localizedString(forIdentifier: locale.code) ?? ""
        }.arguments
    }

    func storePlatforms(_ platforms: [StorePlatform]) throws(MenuExit) -> [String] {
        try subset("Which platforms?", flag: "--platforms", platforms, key: \.key, detail: \.name).arguments
    }

    func pages(_ pages: [CustomPage]) throws(MenuExit) -> [String] {
        try subset("Which custom pages?", flag: "--pages", pages, key: \.key, detail: \.name).arguments
    }

    /// `--dry-run`, `--yes`, or neither to be asked once the plan is shown.
    func writeMode() throws(MenuExit) -> [String] {
        let modes: [(item: Picker.Item, arguments: [String])] = [
            (Picker.Item("Ask", "show the plan, then ask before applying it"), []),
            (Picker.Item("Dry run", "show the plan and write nothing"), ["--dry-run"]),
            (Picker.Item("Apply", "apply the plan without asking"), ["--yes"]),
        ]
        return modes[try choose("Apply the changes?", modes.map(\.item))].arguments
    }

    private func subset<Item>(_ question: String, flag: String, _ items: [Item], key: (Item) -> String,
                              detail: (Item) -> String) throws(MenuExit) -> (chosen: [Item], arguments: [String]) {
        guard items.count > 1 else { return (items, []) }
        let chosen = try tick(question, items.map { Picker.Item(key($0), detail($0)) }, ticked: Set(items.indices)).map { items[$0] }
        return (chosen, chosen.count == items.count ? [] : [flag, chosen.map(key).joined(separator: ",")])
    }
}

// MARK: - Commands

extension MetadataCommand.Check: Guided {}

extension MetadataCommand.Push: Guided {
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        try ask.locales(project.locales) + ask.storePlatforms(project.storePlatforms) + ask.writeMode()
    }
}

extension MetadataCommand.Pull: Guided {
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        let platforms = project.storePlatforms
        guard platforms.count > 1 else { return [] }
        let index = try ask.choose("Read which platform's versions?", platforms.map { Picker.Item($0.key, $0.name) })
        return ["--platform", platforms[index].key]
    }
}

extension ReleaseCommand.New: Guided {
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        [try ask.type("Which version? As App Store Connect spells it: 1.9, 1.9.1.")]
    }
}

extension ProductsCommand.Check: Guided {
    static func isAvailable(in project: Project) -> Bool { project.products != nil }
}

extension ProductsCommand.Push: Guided {
    static func isAvailable(in project: Project) -> Bool { project.products != nil }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] { try ask.writeMode() }
}

extension ProductsCommand.StoreKit: Guided {
    static func isAvailable(in project: Project) -> Bool { project.products?.storeKit != nil }
}

extension ScreenshotsCommand.Capture: Guided {
    static func isAvailable(in project: Project) -> Bool { !project.platforms.isEmpty }

    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        let platforms = try ask.platforms(project.platforms)
        let locales = try ask.locales(project.locales)
        var shots: [Shot] = []
        for shot in platforms.chosen.flatMap({ project.captures(on: $0.kind) }) where !shots.contains(shot) { shots.append(shot) }
        var scopes: [(item: Picker.Item, scope: Scope)] = [
            (Picker.Item("Everything", "the shots, what frames and videos draw, the renders and App Review screenshots"), .everything),
        ]
        if !shots.isEmpty { scopes.append((Picker.Item("Some shots", "only the ones you tick, to look at"), .some)) }
        scopes.append((Picker.Item("Plan only", "show what would be captured, and stop"), .plan))
        let arguments = platforms.arguments + locales
        switch scopes[try ask.choose("What should it capture?", scopes.map(\.item))].scope {
        case .everything:
            return arguments
        case .some:
            let names = shots.map { shot in shot.variant.map { "\(shot.scene):\($0)" } ?? shot.scene }
            let ticked = try ask.tick("Which shots?", names.map { Picker.Item($0) }, ticked: [])
            return arguments + ["--shots", ticked.map { names[$0] }.joined(separator: ",")]
        case .plan:
            return arguments + ["--dry-run"]
        }
    }

    private enum Scope { case everything, some, plan }
}

extension ScreenshotsCommand.Frame: Guided {
    static func isAvailable(in project: Project) -> Bool { project.frames != nil }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        try ask.platforms(project.platforms).arguments + ask.locales(project.locales)
    }
}

extension ScreenshotsCommand.Push: Guided {
    static func isAvailable(in project: Project) -> Bool { project.frames != nil }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        try ask.platforms(project.platforms).arguments + ask.locales(project.locales) + ask.writeMode()
    }
}

extension VideosCommand.Render: Guided {
    static func isAvailable(in project: Project) -> Bool { project.videos != nil }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] { try ask.locales(project.locales) }
}

extension VideosCommand.Push: Guided {
    static func isAvailable(in project: Project) -> Bool { project.videos != nil }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        try ask.locales(project.locales) + ask.writeMode()
    }
}

extension PagesCommand.Push: Guided {
    static func isAvailable(in project: Project) -> Bool { !project.customPages.isEmpty && project.frames != nil }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        let platforms = project.platforms.filter { project.alternatePlatforms.contains($0.kind) }
        return try ask.pages(project.customPages) + ask.platforms(platforms).arguments + ask.locales(project.locales)
            + ask.writeMode()
    }
}

extension ExperimentsCommand.Push: Guided {
    static func isAvailable(in project: Project) -> Bool { !project.experiments.isEmpty && project.frames != nil }
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        try ask.locales(project.locales) + ask.writeMode()
    }
}

extension ReviewCommand: Guided {}

extension ExportCommand: Guided {
    static func arguments(_ ask: Prompter, _ project: Project) throws(MenuExit) -> [String] {
        [try ask.type("Copy the screenshots and videos into which directory?")]
    }
}

extension CacheCommand.Size: Guided {}

extension CacheCommand.Prune: Guided {}

extension DoctorCommand: Guided {}
