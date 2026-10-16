import ArgumentParser
import Foundation
@_exported public import ProductPageKitCore
@_exported public import ProductPageKitFrames

/// The entry point of an app's tools executable:
///
/// ```swift
/// import ProductPageKit
///
/// await ProductPageKit.main(example)
/// ```
public enum ProductPageKit {
    public static func main(_ project: Project) async {
        let session: Session
        do {
            session = try Session(project: project)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
        await Session.$current.withValue(session) {
            await Root.main()
        }
    }
}

struct Root: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "productpage",
        abstract: "Keeps the App Store product page in the repository.",
        subcommands: [MetadataCommand.self, ReleaseCommand.self, ProductsCommand.self, ScreenshotsCommand.self, VideosCommand.self, PagesCommand.self,
                      ReviewCommand.self, ExportCommand.self, CacheCommand.self, DoctorCommand.self]
    )

    /// With no arguments: the menu in a terminal, the help anywhere else.
    func run() async throws {
        let session = try Session.get()
        guard session.console.isInteractive, let terminal = TTY() else { throw CleanExit.helpRequest(self) }
        await Menu(project: session.project, console: session.console, terminal: terminal, run: Self.execute).start()
    }

    /// Parses `arguments` and runs the command they name.
    static func execute(_ arguments: [String]) async throws {
        var command = try parseAsRoot(arguments)
        if var command = command as? any AsyncParsableCommand {
            try await command.run()
        } else {
            try command.run()
        }
    }
}
