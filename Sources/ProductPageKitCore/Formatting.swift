import Foundation

/// `1 screenshot`, `3 screenshots`.
public func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

extension Sequence<UInt8> {
    /// The bytes in lowercase hex, as digests are written.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Array where Element: Hashable {
    /// The values listed more than once, each once.
    var repeated: Set<Element> { Set(filter { value in filter { $0 == value }.count > 1 }) }
}
