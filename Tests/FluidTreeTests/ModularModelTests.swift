import Testing
import FluidJS
@testable import FluidTree

@Test func modularNodeAliasesResolveAndRejectCycles() throws {
    let change = ModularChangeset()
    let a = ChangeAtomId(localId: 1, revision: .root)
    let b = ChangeAtomId(localId: 2, revision: .root)
    let c = ChangeAtomId(localId: 3, revision: .root)
    change.nodeAliases.set(a, b)
    change.nodeAliases.set(b, c)
    change.nodeChanges.set(c, NodeChangeset())
    #expect(try normalizeNodeId(a, aliases: change.nodeAliases) == c)
    _ = try nodeChangeFromId(change, id: a)
    change.nodeAliases.set(c, a)
    #expect(throws: (any Error).self) { try normalizeNodeId(a, aliases: change.nodeAliases) }
}

@Test func modularFieldDispatchPreservesRequiredAndOptionalIdentity() throws {
    let generic = newGenericChangeset([(0, ChangeAtomId(localId: 9, revision: .root))])
    let required = try FieldChangeset.generic(generic).converted(to: .required)
    guard case .optional(let change) = required else {
        Issue.record("Expected optional register representation")
        return
    }
    #expect(change.childChanges == [OptionalChildChange(.active, ChangeAtomId(localId: 9, revision: .root))])
    #expect(throws: (any Error).self) { try FieldChangeset.generic(generic).converted(to: .identifier) }
}
