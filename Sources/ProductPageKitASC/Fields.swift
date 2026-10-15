/// One attribute of a field set, readable as text for comparing and printing.
public struct Property<Root>: Sendable {
    public let name: String
    /// Never printed: a plan shows that it changes, not what to.
    public let isSecret: Bool
    let read: @Sendable (Root) -> String?
    let clear: @Sendable (inout Root) -> Void

    public init<Value: CustomStringConvertible & Sendable>(
        _ name: String, _ keyPath: WritableKeyPath<Root, Value?> & Sendable, secret: Bool = false
    ) {
        self.name = name
        isSecret = secret
        read = { $0[keyPath: keyPath]?.description }
        clear = { $0[keyPath: keyPath] = nil }
    }

    public func value(in root: Root) -> String? { read(root) }
}

/// The writable attributes of a resource, each optional. Nil means "leave it
/// as it is", so the same type describes what a resource holds, what it
/// should hold, and the update that gets it there.
public protocol FieldSet: Equatable, Sendable {
    init()
    static var properties: [Property<Self>] { get }
}

/// One attribute that differs between what is live and what is wanted.
public struct FieldChange: Equatable, Sendable {
    public let name: String
    public let old: String?
    public let new: String
    public let isSecret: Bool

    public init(name: String, old: String?, new: String, isSecret: Bool = false) {
        self.name = name
        self.old = old
        self.new = new
        self.isSecret = isSecret
    }
}

extension FieldSet {
    /// The wanted values that differ from `live`, everything else nil.
    public func changes(from live: Self?) -> Self {
        var changes = self
        for property in Self.properties {
            let wanted = property.read(self)
            if wanted == nil || wanted == live.flatMap(property.read) { property.clear(&changes) }
        }
        return changes
    }

    public var isEmpty: Bool { self == Self() }

    /// Each set attribute of `self`, against its value in `live`.
    public func fieldChanges(from live: Self?) -> [FieldChange] {
        Self.properties.compactMap { property in
            property.read(self).map {
                FieldChange(name: property.name, old: live.flatMap(property.read), new: $0, isSecret: property.isSecret)
            }
        }
    }
}
