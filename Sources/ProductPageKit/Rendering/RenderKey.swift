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

/// Reads the captions a render draws, and collects what is missing or shown
/// in the source language.
struct CaptionReader {
    let copy: StoreCopy
    private(set) var problems: [String] = []
    /// `screenshot.inbox.headline · da`
    private(set) var untranslated: [String] = []

    init(_ copy: StoreCopy) {
        self.copy = copy
    }

    /// The caption, or nil after noting that its headline is missing.
    mutating func caption(_ subject: CaptionSubject, locale: StoreLocale) -> Caption? {
        guard let (caption, missing) = copy.caption(subject, locale: locale) else {
            problems.append("\(Field.caption(subject, .headline).key) has no \(copy.project.primaryLocale.code) value")
            return nil
        }
        untranslated += missing.map { "\($0.key) · \(locale.code)" }
        return caption
    }
}
