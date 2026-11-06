import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

private let session = "00000001-0000-4000-8000-000000000000"

@Test func revisionCodecUsesCompressor() throws {
    let compressor = try IdCompressor(session)
    let codec = RevisionTagCodec(compressor)
    let local = try compressor.generateCompressedId()
    #expect(try codec.encode(.root) == .string("root"))
    #expect(try codec.encode(.compressed(local)) == .number(local))
    let range = try compressor.takeNextCreationRange()
    try compressor.finalizeCreationRange(range)
    let final = try compressor.normalizeToOpSpace(local)
    #expect(final >= 0)
    #expect(try codec.encode(.compressed(local)) == .number(final))
    #expect(try codec.decode(.number(final), originatorId: session) == .compressed(local))
    #expect(throws: (any Error).self) {
        try codec.decode(.string("not-root"), originatorId: session)
    }
}

@Test func atomCodecImplicitRevisionIsContextual() throws {
    let compressor = try IdCompressor(session)
    let codec = ChangeAtomIdCodec(RevisionTagCodec(compressor))
    let revision = RevisionTag.compressed(try compressor.generateCompressedId())
    #expect(try codec.encode(ChangeAtomId(localId: 7), revision: revision) == .number(7))
    #expect(try codec.encode(ChangeAtomId(localId: 7, revision: revision), revision: revision) == .number(7))
    #expect(try codec.decode(.number(7), revision: revision, originatorId: session) == ChangeAtomId(localId: 7, revision: revision))
    let explicit = ChangeAtomId(localId: 7, revision: .root)
    #expect(try codec.encode(explicit, revision: revision) == .array([.number(7), .string("root")]))
    #expect(try codec.decode(.array([.number(7), .string("root")]), revision: revision, originatorId: session) == explicit)
    #expect(throws: (any Error).self) {
        try codec.decode(.array([]), revision: revision, originatorId: session)
    }
}

// Ports all six reserve orders and four modifiers from upstream
// test/feature-libraries/modular-schema/defaultAtomIdAliasAllocator.spec.ts.
@Test func aliasReservationsAreContiguousAndDisjoint() throws {
    let revisions: [RevisionTag?] = [.compressed(-1), .compressed(-2), nil]
    let maxIds: [Double] = [2, 0, 1]
    let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    for order in orders {
        for empty in [false, true] {
            for extra in [false, true] {
                let allocator = DefaultAtomIdAliasAllocator()
                var extras: [Double] = []
                for index in order {
                    try allocator.reserve(revisions[index], maxLocalId: maxIds[index])
                    try allocator.reserve(revisions[index], maxLocalId: maxIds[index])
                    if empty {
                        try allocator.reserve(.compressed(Double(index + 100)), maxLocalId: -1)
                    }
                    if extra {
                        extras.append(try allocator.allocate(100))
                    }
                }
                var aliases: [Double] = []
                for index in 0..<3 {
                    let first = try allocator.getAlias(revisions[index], localId: 0)
                    for local in 0...Int(maxIds[index]) {
                        let alias = try allocator.getAlias(revisions[index], localId: Double(local))
                        #expect(alias == first + Double(local))
                        aliases.append(alias)
                    }
                }
                #expect(Set(aliases).count == 6)
                #expect(allocator.getMaxId() == (extra ? 305 : 5))
                for start in extras {
                    #expect(aliases.allSatisfy { $0 < start || $0 >= start + 100 })
                }
            }
        }
    }
}

@Test func aliasReservationErrorsAreNotSwallowed() throws {
    let allocator = DefaultAtomIdAliasAllocator()
    #expect(throws: (any Error).self) { try allocator.getAlias(nil, localId: 0) }
    try allocator.reserve(nil, maxLocalId: 0)
    #expect(throws: (any Error).self) { try allocator.reserve(nil, maxLocalId: 1) }
    #expect(throws: (any Error).self) { try allocator.getAlias(nil, localId: 1) }
}

@Test func revisionDecodingUsesOriginatorSession() throws {
    let origin = try IdCompressor(session)
    let remote = try IdCompressor("00000002-0000-4000-8000-000000000000")
    let local = try origin.generateCompressedId()
    let range = try origin.takeNextCreationRange()
    try origin.finalizeCreationRange(range)
    try remote.finalizeCreationRange(range)
    let codec = RevisionTagCodec(remote)
    let final = try origin.normalizeToOpSpace(local)
    #expect(try codec.decode(.number(local), originatorId: session) == .compressed(final))
    #expect(try codec.decode(.number(final), originatorId: session) == .compressed(final))
    #expect(try codec.encode(.compressed(final)) == .number(final))
    #expect(throws: (any Error).self) {
        try codec.decode(.number(0.5), originatorId: session)
    }
}
