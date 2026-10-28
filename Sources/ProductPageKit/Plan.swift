import ProductPageKitASC

/// A resource a change acts on: one App Store Connect has, or one an earlier
/// change in the same plan creates.
enum Ref: Hashable, Sendable {
    case existing(String)
    case planned(String)
}

/// One write a command will make, described before it is made.
struct Change: Sendable {
    enum Action: String, Sendable {
        case create, update, upload, replace, place
    }

    let action: Action
    /// What it acts on: `iOS 1.2 · da`, `com.example.plus.monthly`.
    let subject: String
    var fields: [FieldChange] = []
    var lines: [String] = []
    /// The key `Run.created` records this change's new resource under.
    var creates: String?
    /// Whether it may run at the same time as the changes around it that may
    /// too. One that may not runs alone, after everything before it, so what
    /// it creates exists for what comes after.
    var concurrent = false
    let perform: @Sendable (Run) async throws -> Void
}

/// Every change a command would make, in order, and what it noticed on the
/// way that changes nothing but is worth saying.
struct Plan: Sendable {
    var changes: [Change] = []
    var warnings: [String] = []

    mutating func warn(_ message: String) { warnings.append(message) }

    mutating func add(_ change: Change) { changes.append(change) }

    static func + (lhs: Plan, rhs: Plan) -> Plan {
        Plan(changes: lhs.changes + rhs.changes, warnings: lhs.warnings + rhs.warnings)
    }
}

/// Applying a plan: the API, and the ids of what earlier changes created.
actor Run {
    let asc: AppStoreConnect
    private var created: [String: String] = [:]

    init(asc: AppStoreConnect) {
        self.asc = asc
    }

    func id(_ ref: Ref) throws -> String {
        switch ref {
        case .existing(let id): return id
        case .planned(let key):
            guard let id = created[key] else { throw DependencyFailed(key: key) }
            return id
        }
    }

    func record(_ key: String, id: String) { created[key] = id }
}

struct DependencyFailed: Error, CustomStringConvertible {
    let key: String
    var description: String { "skipped, because creating \(key) failed" }
}

extension Plan {
    /// The plan as the person confirming it reads it.
    var lines: [String] {
        changes.flatMap { change in
            [ "  \(change.action.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))\(change.subject)" ]
                + change.fields.flatMap(Self.lines(for:)).map { "            \($0)" }
                + change.lines.map { "            \($0)" }
        }
    }

    static func lines(for field: FieldChange) -> [String] {
        if field.isSecret { return ["\(field.name): \(field.old == nil ? "set" : "changed") (not shown)"] }
        let short = { (value: String) in value.count <= 60 && !value.contains("\n") }
        guard let old = field.old, !old.isEmpty else {
            return short(field.new) ? ["\(field.name): \(field.new)"] : ["\(field.name): \(field.new.count) characters", "  + \(preview(field.new))"]
        }
        if short(old) && short(field.new) { return ["\(field.name): \(old) → \(field.new)"] }
        return ["\(field.name): \(old.count) → \(field.new.count) characters", "  - \(preview(old))", "  + \(preview(field.new))"]
    }

    /// One line of a long value.
    static func preview(_ value: String, width: Int = 64) -> String {
        let flat = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= width ? flat : String(flat.prefix(width - 1)) + "…"
    }
}
