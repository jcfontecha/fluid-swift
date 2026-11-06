import Testing
@testable import FluidTree

@Test func modularEditorAllocatesNestedNodesAndResetsTransactionIds() throws {
    let family = ModularChangeFamily()
    let builder = family.buildEditor { _ in }
    #expect(try builder.generateId(64) == 0)
    let path = FieldUpPath(parent: UpPath(parentField: "a", parentIndex: 2), field: "children")
    let edit = SequenceFieldEditor().insert(0, count: 1, firstId: ChangeAtomId(localId: 0, revision: .root), revision: .root)
    let change = try builder.buildChanges([.field(path: path, change: FieldChange(fieldKind: .sequence, change: .sequence(edit)), revision: .root)])
    let node = ChangeAtomId(localId: 64, revision: .root)
    #expect(change.nodeChanges.has(node))
    #expect(change.nodeToParent.get(node) == FieldId(field: "a"))
    #expect(change.maxId == 64)
    builder.enterTransaction()
    #expect(try builder.generateId() == 0)
    builder.enterTransaction()
    #expect(try builder.generateId() == 1)
    try builder.exitTransaction()
    try builder.exitTransaction()
    #expect(try builder.generateId() == 0)
    #expect(throws: (any Error).self) { try builder.exitTransaction() }
}

@Test func modularEditorGatesNoChangeConstraintsAtClient280() throws {
    let old = ModularChangeFamily().buildEditor { _ in }
    #expect(throws: (any Error).self) { try old.addNoChangeConstraint(revision: .root) }
    var received: [TaggedChange<ModularChangeset>] = []
    let current = ModularChangeFamily(minimumClientVersion: .v2_80).buildEditor { received.append($0) }
    try current.addNoChangeConstraint(revision: .root)
    #expect(received.count == 1)
    #expect(received.first?.change.noChangeConstraint?.violated == false)
    #expect(received.first?.change.maxId == nil)
}
