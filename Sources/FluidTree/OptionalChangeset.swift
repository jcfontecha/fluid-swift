import FluidJS

/// feature-libraries/optional-field/optionalFieldChangeTypes.ts.
public struct OptionalMove: Equatable, Sendable {
    public var src: ChangeAtomId
    public var dst: ChangeAtomId
    public init(_ src: ChangeAtomId, _ dst: ChangeAtomId) {
        self.src = src
        self.dst = dst
    }
}
public struct OptionalChildChange: Equatable, Sendable {
    public var register: RegisterId
    public var change: ChangeAtomId
    public init(_ register: RegisterId, _ change: ChangeAtomId) {
        self.register = register
        self.change = change
    }
}
public struct OptionalReplace: Equatable, Sendable {
    public var isEmpty: Bool
    public var src: RegisterId?
    public var dst: ChangeAtomId
    public var sourceFirst: Bool
    public init(isEmpty: Bool, src: RegisterId? = nil, dst: ChangeAtomId, sourceFirst: Bool = true) {
        self.sourceFirst = sourceFirst
        self.isEmpty = isEmpty
        self.src = src
        self.dst = dst
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.isEmpty == rhs.isEmpty && lhs.src == rhs.src && lhs.dst == rhs.dst }
    var isEffectful: Bool { src != .active && (!isEmpty || src != nil) }
    var effectfulDst: ChangeAtomId? { isEmpty || src == .active ? nil : dst }
}
public struct OptionalChangeset: Equatable, Sendable {
    public var moves: [OptionalMove]
    public var childChanges: [OptionalChildChange]
    public var valueReplace: OptionalReplace?
    var childrenFirst = false
    public init(moves: [OptionalMove] = [], childChanges: [OptionalChildChange] = [], valueReplace: OptionalReplace? = nil) {
        self.moves = moves
        self.childChanges = childChanges
        self.valueReplace = valueReplace
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.moves == rhs.moves && lhs.childChanges == rhs.childChanges && lhs.valueReplace == rhs.valueReplace }
    public var isEmpty: Bool { moves.isEmpty && childChanges.isEmpty && valueReplace == nil }
}

/// feature-libraries/optional-field/optionalField.ts: optionalFieldEditor.
public struct OptionalFieldEditor {
    public init() {}
    public func set(wasEmpty: Bool, fill: ChangeAtomId, detach: ChangeAtomId) -> OptionalChangeset {
        OptionalChangeset(valueReplace: OptionalReplace(isEmpty: wasEmpty, src: .detached(fill), dst: detach))
    }
    public func clear(wasEmpty: Bool, detachId: ChangeAtomId) -> OptionalChangeset {
        OptionalChangeset(valueReplace: OptionalReplace(isEmpty: wasEmpty, dst: detachId))
    }
    public func buildChildChanges(_ changes: [(Int, ChangeAtomId)]) throws -> OptionalChangeset {
        guard changes.count <= 1 else { throw JSONDecodingError("0xabd: optional field supports one child") }
        let children = try changes.map { index, change in
            guard index == 0 else { throw JSONDecodingError("0x404: optional child index must be zero") }
            return OptionalChildChange(.active, change)
        }
        return OptionalChangeset(childChanges: children)
    }
}
