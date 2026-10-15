import Foundation
@testable import ProductPageKitCore

/// A temporary directory with a `.git` folder, removed when released.
final class TemporaryRepository {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "ProductPageKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: ".git"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to path: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appending(path: path), encoding: .utf8)
    }
}

func project(locales: [StoreLocale] = [StoreLocale("en", store: "en-US")], products: Products? = nil) -> Project {
    Project(
        name: "Example",
        bundleID: "com.example.app",
        locales: locales,
        platforms: [.iPhone(), .mac()],
        metadata: Metadata(
            urls: URLs(marketing: "https://example.com", support: "https://example.com/support",
                       privacy: "https://example.com/privacy"),
            copyright: "2026 Example",
            requiredLinks: [.description: ["https://example.com/terms"]],
            fallbackKeywords: "fallback,keywords"
        ),
        products: products
    )
}
