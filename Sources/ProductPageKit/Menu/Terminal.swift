import Foundation

/// A line of the menu's screen, in runs of one style each.
struct Line: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case plain, bold, dim, inverse
        /// A message the screen needs noticed.
        case warning
    }

    struct Run: Equatable, Sendable {
        let text: String
        let style: Style
    }

    var runs: [Run]

    init(_ text: String = "", _ style: Style = .plain) {
        runs = text.isEmpty ? [] : [Run(text: text, style: style)]
    }

    init(runs: [Run]) {
        self.runs = runs
    }

    var text: String { runs.map(\.text).joined() }
}

/// Where the menu draws and reads keys: the terminal, or a script in tests.
protocol MenuTerminal: AnyObject {
    /// Takes keys one at a time, unechoed, and shows a screen of the menu's
    /// own with the cursor hidden.
    func open()
    /// Puts the terminal back as it was, and the screen with it.
    func close()
    /// The next key, or nil once input has ended.
    func readKey() -> Key?
    /// Replaces the screen with `lines`, each cut to the width.
    func draw(_ lines: [Line])
    var rows: Int { get }
}

/// The terminal the command runs in, through its termios settings and ANSI
/// escape sequences.
final class TTY: MenuTerminal {
    private var original = termios()

    /// Nil when standard input or output is not a terminal.
    init?() {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
    }

    func open() {
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    func close() {
        write("\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    func readKey() -> Key? {
        KeyDecoder.key { wait in
            // 50 ms tells a lone Escape from the rest of a sequence, which
            // a terminal sends in one write.
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, wait ? -1 : 50) > 0 else { return nil }
            var byte: UInt8 = 0
            return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
        }
    }

    func draw(_ lines: [Line]) {
        let width = columns
        var screen = "\u{1B}[H"
        for line in lines.prefix(rows) {
            screen += "\u{1B}[2K" + Self.render(line, width: width) + "\r\n"
        }
        write(screen + "\u{1B}[J")
    }

    var rows: Int { size.ws_row > 0 ? Int(size.ws_row) : 24 }

    private var columns: Int { size.ws_col > 0 ? Int(size.ws_col) : 80 }

    private var size: winsize {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        return size
    }

    /// The line's runs in their styles, cut at `width` characters.
    static func render(_ line: Line, width: Int) -> String {
        var remaining = width
        var output = ""
        for run in line.runs where remaining > 0 {
            let text = String(run.text.prefix(remaining))
            remaining -= text.count
            output += style(run.style) + text + "\u{1B}[0m"
        }
        return output
    }

    private static func style(_ style: Line.Style) -> String {
        switch style {
        case .plain: ""
        case .bold: "\u{1B}[1m"
        case .dim: "\u{1B}[2m"
        case .inverse: "\u{1B}[7m"
        case .warning: "\u{1B}[33m"
        }
    }

    private func write(_ text: String) {
        var text = text
        text.withUTF8 { _ = Foundation.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    }
}
