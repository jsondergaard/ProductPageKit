import CryptoKit
import Foundation
import ProductPageKitCore

/// The name of a rendered file: a hash of everything it is drawn from. The
/// tools executable is part of it, since the theme is code compiled into it,
/// so a theme change redraws everything and nothing else does.
struct RenderKey {
    private var hash = SHA256()

    init(_ kind: String) {
        add(kind)
        add(Self.renderer)
    }

    mutating func add(_ string: String) {
        add(Data(string.utf8))
    }

    mutating func add(_ data: Data) {
        hash.update(data: withUnsafeBytes(of: UInt64(data.count).littleEndian) { Data($0) })
        hash.update(data: data)
    }

    mutating func add(_ caption: Caption) {
        for line in [caption.kicker ?? "", caption.headline, caption.subline ?? ""] { add(line) }
        add(caption.checklist.joined(separator: "\n"))
    }

    func finalize() -> String {
        hash.finalize().prefix(16).hex
    }

    /// The running executable's digest.
    static let renderer: String = {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return "unknown"
        }
        return SHA256.hash(data: data).hex
    }()
}

/// What stops one screenshot or video from being drawn in a locale.
struct RenderProblem<Item: Hashable & Sendable>: CustomStringConvertible, Sendable {
    let item: Item
    /// What is missing or wrong: `no iPhone 6.9" capture of list`.
    let reason: String
    /// The reason with what it stops, for the command line.
    let description: String
}

/// Reads the captions a render draws, and collects the lines shown in the
/// source language.
struct CaptionReader {
    let copy: StoreCopy
    /// `screenshot.inbox.headline · da`
    private(set) var untranslated: [String] = []

    init(_ copy: StoreCopy) {
        self.copy = copy
    }

    /// The caption, or why there is none: its headline is missing.
    mutating func caption(_ subject: CaptionSubject, locale: StoreLocale) -> Result<Caption, MissingHeadline> {
        guard let (caption, missing) = copy.caption(subject, locale: locale) else {
            return .failure(MissingHeadline(
                description: "\(Field.caption(subject, .headline).key) has no \(copy.project.primaryLocale.code) value"))
        }
        untranslated += missing.map { "\($0.key) · \(locale.code)" }
        return .success(caption)
    }

    struct MissingHeadline: Error, CustomStringConvertible {
        let description: String
    }
}
