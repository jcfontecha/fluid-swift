import FluidJS

/// feature-libraries/modular-schema/defaultAtomIdAliasAllocator.ts.
public final class DefaultAtomIdAliasAllocator {
    private struct Reservation {
        let offset: Double
        let originalMaxLocalId: Double
    }
    private var offsets: [RevisionTag?: Reservation] = [:]
    private var maxId: Double = -1

    public init() {}

    public func reserve(_ revision: RevisionTag?, maxLocalId: Double) throws {
        if let current = offsets[revision] {
            guard current.originalMaxLocalId == maxLocalId else {
                throw JSONDecodingError("0xd3f: inconsistent original max local ID")
            }
            return
        }
        let offset = maxLocalId < 0 ? maxId : try allocate(maxLocalId + 1)
        offsets[revision] = Reservation(offset: offset, originalMaxLocalId: maxLocalId)
    }

    public func getAlias(_ revision: RevisionTag?, localId: Double) throws -> Double {
        guard let current = offsets[revision] else {
            throw JSONDecodingError("0xd40: no alias reserved")
        }
        guard localId <= current.originalMaxLocalId else {
            throw JSONDecodingError("0xd41: original local ID exceeds reservation")
        }
        return localId + current.offset
    }

    public func allocate(_ count: Double = 1) throws -> Double {
        guard count > 0 else {
            throw JSONDecodingError("0x5cf: must allocate at least one ID")
        }
        let first = maxId + 1
        maxId += count
        return first
    }

    public func getMaxId() -> Double {
        maxId
    }
}
