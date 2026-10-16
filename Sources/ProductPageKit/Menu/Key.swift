/// A key pressed in the menu.
enum Key: Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown
    case enter, space, escape, backspace
    /// Control-C, which raw mode delivers as a key rather than a signal.
    case interrupt
    case character(Character)
    /// A sequence the menu has no use for, such as a function key.
    case other
}

/// Turns the bytes a terminal sends into keys.
enum KeyDecoder {
    /// The next key, or nil at the end of input. `next` returns the next
    /// byte, blocking when `wait` is true and otherwise giving up after a
    /// moment: that is how a lone Escape is told from the start of an arrow
    /// key's sequence.
    static func key(_ next: (_ wait: Bool) -> UInt8?) -> Key? {
        guard let byte = next(true) else { return nil }
        switch byte {
        case 0x03: return .interrupt
        case 0x0A, 0x0D: return .enter
        case 0x1B: return escape(next)
        case 0x20: return .space
        case 0x08, 0x7F: return .backspace
        case 0x00..<0x20: return .other
        default: return character(byte, next)
        }
    }

    /// `ESC [ A` and `ESC O A` are both the up arrow, depending on the
    /// terminal's mode; `ESC [ 5 ~` is Page Up.
    private static func escape(_ next: (Bool) -> UInt8?) -> Key {
        guard let introducer = next(false) else { return .escape }
        guard introducer == UInt8(ascii: "[") || introducer == UInt8(ascii: "O") else { return .other }
        var parameters = ""
        while let byte = next(false) {
            guard (0x40...0x7E).contains(byte) else {
                parameters.append(Character(UnicodeScalar(byte)))
                continue
            }
            switch (Character(UnicodeScalar(byte)), parameters) {
            case ("A", _): return .up
            case ("B", _): return .down
            case ("C", _): return .right
            case ("D", _): return .left
            case ("H", _), ("~", "1"), ("~", "7"): return .home
            case ("F", _), ("~", "4"), ("~", "8"): return .end
            case ("~", "5"): return .pageUp
            case ("~", "6"): return .pageDown
            default: return .other
            }
        }
        return .other
    }

    /// A character of one to four UTF-8 bytes, the lead byte giving the count.
    private static func character(_ lead: UInt8, _ next: (Bool) -> UInt8?) -> Key {
        let count = switch lead {
        case 0xF0...: 4
        case 0xE0...: 3
        case 0xC0...: 2
        default: 1
        }
        var bytes = [lead]
        while bytes.count < count, let byte = next(false) { bytes.append(byte) }
        guard let character = String(validating: bytes, as: UTF8.self)?.first else { return .other }
        return .character(character)
    }
}
