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
}
