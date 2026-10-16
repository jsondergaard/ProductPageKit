/// How a question was left without an answer.
enum MenuExit: Error, Equatable {
    case back
    case quit
}

/// Asks questions on the menu's screen, one screen each, under the path to
/// the command they are for: `productpage › screenshots › capture`.
final class Prompter {
    private let terminal: any MenuTerminal
    var path: [String]

    /// The lines around a list: the path, the question, and the notice and
    /// key hints below it.
    static let chrome = 7

    init(terminal: any MenuTerminal, path: [String]) {
        self.terminal = terminal
        self.path = path
    }

    /// The index of the item chosen.
    func choose(_ question: String, _ items: [Picker.Item], cursor: Int = 0) throws(MenuExit) -> Int {
        try pick(question, Picker(items, mode: .one, cursor: cursor))[0]
    }

    /// The indices of the items ticked, `ticked` to start with.
    func tick(_ question: String, _ items: [Picker.Item], ticked: Set<Int>) throws(MenuExit) -> [Int] {
        try pick(question, Picker(items, mode: .many, ticked: ticked))
    }

    func type(_ question: String) throws(MenuExit) -> String {
        var field = TextField()
        while true {
            draw(question, [Line(runs: [Line.Run(text: "› ", style: .dim), Line.Run(text: field.text + "▏", style: .plain)])],
                 status: field.notice.map { Line($0, .warning) }, hint: "return confirm · esc back")
            guard let key = terminal.readKey() else { throw .quit }
            switch field.handle(key) {
            case .value(let text): return text
            case .back: throw .back
            case .quit: throw .quit
            case nil: continue
            }
        }
    }

    private func pick(_ question: String, _ start: Picker) throws(MenuExit) -> [Int] {
        var picker = start
        let height = max(1, terminal.rows - Self.chrome)
        let back = path.count > 1 ? " · ← back" : ""
        let hint = picker.mode == .one
            ? "↑↓ move · return choose\(back) · q quit"
            : "↑↓ move · space tick · a all or none · return confirm\(back) · q quit"
        while true {
            let status = picker.notice.map { Line($0, .warning) } ?? picker.position(height: height).map { Line($0, .dim) }
            draw(question, picker.lines(height: height), status: status, hint: hint)
            guard let key = terminal.readKey() else { throw .quit }
            switch picker.handle(key, height: height) {
            case .value(let indices): return indices
            case .back: throw .back
            case .quit: throw .quit
            case nil: continue
            }
        }
    }

    private func draw(_ question: String, _ body: [Line], status: Line?, hint: String) {
        terminal.draw([Line(path.joined(separator: " › "), .dim), Line(), Line(question, .bold), Line()] + body
            + [Line(), status ?? Line(), Line(hint, .dim)])
    }
}
