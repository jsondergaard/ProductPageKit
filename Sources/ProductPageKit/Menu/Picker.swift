import Foundation

/// What a question on the menu's screen ends with.
enum Answer<Value: Equatable>: Equatable {
    case value(Value)
    case back
    case quit
}

/// A list to choose one item from, or to tick any number of: the cursor,
/// the ticks, and which part of a long list is in view.
struct Picker: Equatable {
    struct Item: Equatable {
        let title: String
        let detail: String

        init(_ title: String, _ detail: String = "") {
            self.title = title
            self.detail = detail
        }
    }

    enum Mode: Equatable { case one, many }

    let items: [Item]
    let mode: Mode
    private(set) var cursor: Int
    private(set) var ticked: Set<Int>
    /// The first item in view.
    private(set) var top = 0
    /// Why the last key did nothing, until the next.
    private(set) var notice: String?

    init(_ items: [Item], mode: Mode, cursor: Int = 0, ticked: Set<Int> = []) {
        self.items = items
        self.mode = mode
        self.cursor = min(max(0, cursor), max(0, items.count - 1))
        self.ticked = ticked
    }

    /// Moves, ticks or answers for `key`, with `height` items in view.
    mutating func handle(_ key: Key, height: Int) -> Answer<[Int]>? {
        notice = nil
        let last = items.count - 1
        switch key {
        case .up, .character("k"): cursor = max(0, cursor - 1)
        case .down, .character("j"): cursor = min(last, cursor + 1)
        case .home: cursor = 0
        case .end: cursor = last
        case .pageUp: cursor = max(0, cursor - height)
        case .pageDown: cursor = min(last, cursor + height)
        case .space where mode == .many:
            if ticked.contains(cursor) { ticked.remove(cursor) } else { ticked.insert(cursor) }
        case .character("a") where mode == .many:
            ticked = ticked.count == items.count ? [] : Set(items.indices)
        case .enter, .right, .character("l"):
            guard mode == .many else { return .value([cursor]) }
            guard !ticked.isEmpty else {
                notice = "Tick at least one with space."
                return nil
            }
            return .value(ticked.sorted())
        case .left, .escape, .backspace, .character("h"): return .back
        case .interrupt, .character("q"): return .quit
        default: break
        }
        top = min(max(top, cursor - height + 1), cursor)
        return nil
    }

    /// The items in view, the one under the cursor highlighted, titles in a
    /// column and details dimmed beside them.
    func lines(height: Int) -> [Line] {
        let column = (items.map(\.title.count).max() ?? 0) + 3
        let visible = items.indices.dropFirst(top).prefix(height)
        return visible.map { index in
            let item = items[index]
            let mark = switch mode {
            case .one: index == cursor ? "› " : "  "
            case .many: ticked.contains(index) ? "[x] " : "[ ] "
            }
            let title = mark + item.title.padding(toLength: column, withPad: " ", startingAt: 0)
            return Line(runs: [Line.Run(text: title, style: index == cursor ? .inverse : .plain),
                               Line.Run(text: item.detail, style: .dim)])
        }
    }

    /// Where the view is in a list longer than it: `11–20 of 30`.
    func position(height: Int) -> String? {
        guard items.count > height else { return nil }
        return "\(top + 1)–\(min(items.count, top + height)) of \(items.count)"
    }
}

/// A line of text typed in.
struct TextField: Equatable {
    private(set) var text: String
    private(set) var notice: String?

    init(_ text: String = "") {
        self.text = text
    }

    mutating func handle(_ key: Key) -> Answer<String>? {
        notice = nil
        switch key {
        case .character(let character): text.append(character)
        case .space: text.append(" ")
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .enter:
            let answer = text.trimmingCharacters(in: .whitespaces)
            guard !answer.isEmpty else {
                notice = "Type an answer, or press Escape to go back."
                return nil
            }
            return .value(answer)
        case .escape: return .back
        case .interrupt: return .quit
        default: break
        }
        return nil
    }
}
