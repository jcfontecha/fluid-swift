import FluidJS

/// memoryBlobStorage.ts createMemoryDetachedBlobStorage: numeric, insertion-ordered local IDs.
final class MemoryDetachedBlobStorage {
    private var blobs: [[UInt8]] = []
    var size: Int { blobs.count }

    func createBlob(_ bytes: [UInt8]) -> JSString {
        let id = JSString(String(blobs.count))
        blobs.append(bytes)
        return id
    }

    func getBlobIds() -> [JSString] {
        blobs.indices.map { JSString(String($0)) }
    }

    func readBlob(_ id: JSString) throws -> [UInt8] {
        guard let index = Int(id.description), blobs.indices.contains(index) else {
            throw JSONDecodingError("Blob not found: \(id)")
        }
        return blobs[index]
    }

    func dispose() {
        blobs.removeAll()
    }
}
