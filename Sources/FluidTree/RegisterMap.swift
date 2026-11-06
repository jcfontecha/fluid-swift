/// Insertion-ordered map used to reproduce JavaScript Map iteration.
public struct OrderedMap<Key: Hashable, Value> {
    private var order: [Key] = []
    private var values: [Key: Value] = [:]
    public init() {}
    public var count: Int { order.count }
    public var keys: [Key] { order }
    public var entries: [(Key, Value)] {
        order.compactMap { key in values[key].map { (key, $0) } }
    }
    public var isEmpty: Bool { order.isEmpty }
    public subscript(_ key: Key) -> Value? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { order.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                order.removeAll { $0 == key }
            }
        }
    }
}

/// feature-libraries/optional-field/optionalFieldChangeTypes.ts: "self" is the live register.
public enum RegisterId: Hashable, Sendable {
    case active
    case detached(ChangeAtomId)
}

/// feature-libraries/optional-field/optionalField.ts: RegisterMap.
/// Upstream groups by local ID first, then revision, rather than insertion order
/// across whole atom IDs. The live register occupies its own outer key.
public final class RegisterMap<Value> {
    private var data = OrderedMap<Double?, OrderedMap<RevisionTag?, Value>>()
    public init() {}
    public var keys: [RegisterId] { entries.map(\.0) }
    public var entries: [(RegisterId, Value)] {
        data.entries.flatMap { localId, revisions in
            revisions.entries.map { revision, value in
                (localId.map { RegisterId.detached(ChangeAtomId(localId: $0, revision: revision)) } ?? .active, value)
            }
        }
    }
    public func clone() -> RegisterMap<Value> {
        let clone = RegisterMap<Value>()
        clone.data = data
        return clone
    }
    public func set(_ id: RegisterId, _ value: Value) {
        let (localId, revision) = keys(id)
        var inner = data[localId] ?? OrderedMap()
        inner[revision] = value
        data[localId] = inner
    }
    public func get(_ id: RegisterId) -> Value? {
        let (localId, revision) = keys(id)
        return data[localId]?[revision]
    }
    public func delete(_ id: RegisterId) {
        let (localId, revision) = keys(id)
        guard var inner = data[localId] else { return }
        inner[revision] = nil
        data[localId] = inner.isEmpty ? nil : inner
    }
    private func keys(_ id: RegisterId) -> (Double?, RevisionTag?) {
        switch id {
        case .active: return (nil, nil)
        case .detached(let atom): return (atom.localId, atom.revision)
        }
    }
}

/// core/rebase/types.ts: ChangeAtomIdMap groups revision first, then local ID.
struct ChangeAtomIdMap<Value> {
    private var data = OrderedMap<RevisionTag?, OrderedMap<Double, Value>>()
    var entries: [(ChangeAtomId, Value)] {
        data.entries.flatMap { revision, inner in
            inner.entries.map { localId, value in (ChangeAtomId(localId: localId, revision: revision), value) }
        }
    }
    subscript(_ atom: ChangeAtomId) -> Value? {
        get { data[atom.revision]?[atom.localId] }
        set {
            var inner = data[atom.revision] ?? OrderedMap()
            inner[atom.localId] = newValue
            data[atom.revision] = inner.isEmpty ? nil : inner
        }
    }
}

extension OrderedMap: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.order == rhs.order && lhs.values == rhs.values
    }
}
