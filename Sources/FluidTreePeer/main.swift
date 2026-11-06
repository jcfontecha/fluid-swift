import Foundation
import FluidJS
import FluidIdCompressor
import FluidTree

private struct Edit {
    enum Kind: String { case insert, remove, move, revive, set, clear, crossMove, nested }
    enum Cell { case live, detached(edit: Int, localId: Double) }
    let kind: Kind
    let index: Int
    let count: Int
    let destination: Int
    let field: JSString
    let base: Int?
    let detach: (edit: Int, localId: Double)?
    let wasEmpty: Bool
    let cells: [Cell]?
    init(_ value: JSONValue) throws {
        guard let kind = Kind(rawValue: try value.member("kind").asString().description) else { throw JSONDecodingError("unknown edit kind") }
        self.kind = kind
        index = try value.member("index").asInt()
        count = try value.member("count").asInt()
        destination = try value.member("destination").asInt()
        field = try value.member("field").asString()
        guard index >= 0 && count >= 0 && destination >= 0 && (field == "a" || field == "b") else { throw JSONDecodingError("invalid edit") }
        let object = try value.asObject()
        base = try object["base"].map { try $0.asInt() }
        detach = try object["detach"].map { value in (try value.member("edit").asInt(), try value.member("localId").asNumber()) }
        if let empty = object["wasEmpty"] {
            guard case .bool(let empty) = empty else { throw JSONDecodingError("invalid optional state") }
            wasEmpty = empty
        } else { wasEmpty = false }
        cells = try object["cells"].map { value in
            try value.asArray().map { value in
                guard case .bool(let live) = try value.member("live") else { throw JSONDecodingError("invalid cell state") }
                return live ? .live : .detached(edit: try value.member("edit").asInt(), localId: try value.member("localId").asNumber())
            }
        }
    }
}

private final class NativeOracle {
    let compressor: IdCompressor
    let family: ModularChangeFamily
    let revisions: RevisionTagCodec
    var editRevisions: [RevisionTag] = []
    init() throws {
        compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
        revisions = RevisionTagCodec(compressor)
        family = ModularChangeFamily()
    }
    func mint() throws -> RevisionTag { .compressed(try compressor.generateCompressedId()) }
    func priorRevision(_ index: Int) throws -> RevisionTag {
        guard editRevisions.indices.contains(index) else { throw JSONDecodingError("missing detach revision") }
        return editRevisions[index]
    }
    func build(_ edit: Edit) throws -> TaggedChange<ModularChangeset> {
        let revision = try mint()
        editRevisions.append(revision)
        let atom = ChangeAtomId(localId: 0, revision: revision)
        let attach = ChangeAtomId(localId: 8, revision: revision)
        let path = FieldUpPath(field: edit.field)
        let other = FieldUpPath(field: edit.field == "a" ? "b" : "a")
        let builder = family.buildEditor { _ in }
        _ = try builder.generateId(64)
        let seq = SequenceFieldEditor()
        func description(_ path: FieldUpPath, _ marks: [SequenceMark]) -> EditDescription {
            .field(path: path, change: FieldChange(fieldKind: .sequence, change: .sequence(marks)), revision: revision)
        }
        let edits: [EditDescription]
        switch edit.kind {
        case .insert: edits = [description(path, seq.insert(edit.index, count: edit.count, firstId: atom, revision: revision))]
        case .remove: edits = [description(path, seq.remove(edit.index, count: edit.count, id: 0, revision: revision))]
        case .move: edits = [description(path, seq.move(edit.index, count: edit.count, destination: edit.destination, detachCellId: 0, attachCellId: attach, revision: revision))]
        case .revive:
            if let cells = edit.cells {
                let factory = MarkListFactory()
                for cell in cells {
                    switch cell {
                    case .live: factory.pushOffset(1)
                    case .detached(let index, let localId):
                        let cellId = ChangeAtomId(localId: localId, revision: try priorRevision(index))
                        let selected = edit.detach.map { index == $0.edit && localId >= $0.localId && localId < $0.localId + Double(edit.count) } ?? false
                        factory.push(SequenceMark(count: 1, effect: selected ? .insert(id: localId, revision: revision) : .noop, cellId: cellId, propertyOrder: selected ? [.count, .cellId, .type, .id, .revision] : [.count, .cellId]))
                    }
                }
                edits = [description(path, factory.list)]
            } else {
                let detach = try edit.detach.map { ChangeAtomId(localId: $0.localId, revision: try priorRevision($0.edit)) } ?? ChangeAtomId(localId: 32, revision: .root)
                edits = [description(path, try seq.revive(edit.index, count: edit.count, detachEvent: detach, revision: revision))]
            }
        case .crossMove:
            edits = [description(path, seq.moveOut(edit.index, count: edit.count, id: 0, revision: revision)), description(other, seq.moveIn(edit.destination, count: edit.count, moveId: 0, attachCellId: attach, revision: revision))]
        case .set, .clear:
            let optional = edit.kind == .set ? OptionalFieldEditor().set(wasEmpty: edit.wasEmpty, fill: attach, detach: atom) : OptionalFieldEditor().clear(wasEmpty: edit.wasEmpty, detachId: atom)
            edits = [.field(path: FieldUpPath(field: "optional"), change: FieldChange(fieldKind: .optional, change: .optional(optional)), revision: revision)]
        case .nested:
            edits = [description(FieldUpPath(parent: UpPath(parentField: edit.field, parentIndex: edit.index), field: "children"), seq.insert(0, count: edit.count, firstId: atom, revision: revision))]
        }
        return TaggedChange(change: try builder.buildChanges(edits), revision: revision)
    }
    func bytes(_ change: ModularChangeset, versions: [Int] = [5], revision: RevisionTag? = nil) throws -> [String] {
        let context = ModularCodecContext(revision: revision, originatorId: compressor.localSessionId)
        return try versions.map { version in
            let codec = try ModularChangeCodec(version: version, revisionTagCodec: revisions, storageContext: family.context)
            let encoded = try codec.encode(change, context: context)
            let bytes = JSON.stringify(encoded)
            let decoded = try codec.decode(encoded, context: context)
            guard try JSON.stringify(codec.encode(decoded, context: context)) == bytes else { throw JSONDecodingError("native codec byte roundtrip failed") }
            return bytes
        }
    }
    func rebase(_ change: TaggedChange<ModularChangeset>, over base: TaggedChange<ModularChangeset>, history: [RevisionInfo] = []) throws -> TaggedChange<ModularChangeset> {
        var infos = OrderedMap<RevisionTag, RevisionInfo>()
        for info in history + (base.change.revisions ?? []) + (change.change.revisions ?? []) { infos[info.revision] = info }
        let result = try family.rebase(change, over: base, metadata: RevisionMetadataSource(infos.entries.map(\.1)))
        return TaggedChange(change: result, revision: change.revision)
    }
    func runAxioms(_ specs: [Edit], edits: [TaggedChange<ModularChangeset>], record: (ModularChangeset) throws -> Void) throws {
        let empty = TaggedChange(change: ModularChangeset(context: family.context))
        func rollback(_ change: TaggedChange<ModularChangeset>) throws -> TaggedChange<ModularChangeset> {
            let revision = try mint()
            return TaggedChange(change: try family.invert(change, isRollback: true, revision: revision), revision: revision, rollbackOf: change.revision)
        }
        for edit in edits {
            try record(family.compose([edit, empty]))
            try record(family.compose([empty, edit]))
            try record(rebase(empty, over: edit).change)
            let inverse = try rollback(edit)
            try record(inverse.change)
            try record(family.compose([edit, inverse]))
        }
        var groups = OrderedMap<Int?, [Int]>()
        for (index, spec) in specs.enumerated() {
            var group = groups[spec.base] ?? []
            group.append(index)
            groups[spec.base] = group
        }
        for (_, indices) in groups.entries where indices.count > 1 {
            for index in 1..<indices.count {
                let ai = indices[index - 1]
                let a = edits[ai]
                let b = edits[indices[index]]
                let rebased = try rebase(b, over: a)
                try record(rebased.change)
                let inverse = try rollback(a)
                try record(inverse.change)
                let restored = try rebase(rebased, over: inverse, history: a.change.revisions ?? [])
                try record(restored.change)
                try record(rebase(restored, over: a).change)
                if index + 1 < indices.count {
                    let c = edits[indices[index + 1]]
                    let third = try rebase(rebase(c, over: a), over: rebased)
                    let ab = TaggedChange(change: try family.compose([a, rebased]))
                    let bc = TaggedChange(change: try family.compose([rebased, third]))
                    let left = try family.compose([ab, third])
                    let right = try family.compose([a, bc])
                    let balanced = try family.compose([a, rebased, third])
                    try record(left)
                    try record(right)
                    try record(balanced)
                }
                if let childIndex = specs.firstIndex(where: { $0.base == ai }) {
                    let child = edits[childIndex]
                    let aPrime = try rebase(a, over: b)
                    try record(aPrime.change)
                    var infos = OrderedMap<RevisionTag, RevisionInfo>()
                    for change in [inverse, b, aPrime, child] {
                        for info in change.change.revisions ?? [] { infos[info.revision] = info }
                    }
                    let history = infos.entries.map(\.1)
                    let first = try rebase(child, over: inverse, history: history)
                    try record(first.change)
                    let second = try rebase(first, over: b, history: history)
                    try record(second.change)
                    let sequential = try rebase(second, over: aPrime, history: history)
                    try record(sequential.change)
                    let sandwich = try family.compose([inverse, b, aPrime])
                    try record(sandwich)
                    let leftSandwich = try family.compose([TaggedChange(change: family.compose([inverse, b])), aPrime])
                    try record(leftSandwich)
                    try record(rebase(child, over: TaggedChange(change: leftSandwich), history: history).change)
                }
            }
        }
    }
    func run(_ scenario: JSONValue) throws -> JSONValue {
        let specs = try scenario.member("edits").asArray().map(Edit.init)
        let edits = try specs.map(build)
        var output: [[String]] = []
        func record(_ change: ModularChangeset) throws {
            var row = try bytes(change)
            if !CommandLine.arguments.contains("--wire-only") { row.append(try JSON.stringify(modularStructure(change))) }
            output.append(row)
        }
        for change in edits {
            output.append(try bytes(change.change, versions: [3, 4, 5, 5], revision: change.revision))
            try record(change.change)
            try record(family.invert(change, isRollback: false, revision: mint()))
            try record(family.invert(change, isRollback: true, revision: mint()))
            try record(family.compose([change]))
            try record(rebase(change, over: TaggedChange(change: ModularChangeset(context: family.context))).change)
        }
        var groups = OrderedMap<Int?, [TaggedChange<ModularChangeset>]>()
        for (index, edit) in edits.enumerated() {
            let key = specs[index].base
            var group = groups[key] ?? []
            group.append(edit)
            groups[key] = group
        }
        for (_, group) in groups.entries where group.count > 1 {
            for index in 1..<group.count {
                let a = group[index - 1]
                let b = group[index]
                let rebased = try rebase(b, over: a)
                try record(rebased.change)
                let composed = try family.compose([a, rebased])
                try record(composed)
                let inverseRevision = try mint()
                let inverse = TaggedChange(change: try family.invert(a, isRollback: true, revision: inverseRevision), revision: inverseRevision, rollbackOf: a.revision)
                try record(rebase(rebased, over: inverse, history: a.change.revisions ?? []).change)
                if index + 1 < group.count {
                    let c = group[index + 1]
                    let sequential = try rebase(rebase(c, over: a), over: rebased)
                    let combined = try rebase(c, over: TaggedChange(change: composed))
                    try record(sequential.change)
                    try record(combined.change)
                }
            }
        }
        try runAxioms(specs, edits: edits, record: record)
        return .array(output.map { .array($0.map { .string(JSString($0)) }) })
    }
}

// Full wire and tagged-structure transport. --wire-only is an explicit diagnostic mode.
while let line = readLine() {
    do {
        let result = try NativeOracle().run(JSON.parse(line))
        FileHandle.standardOutput.write(Data((JSON.stringify(result) + "\n").utf8))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
