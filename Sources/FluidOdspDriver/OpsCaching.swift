import FluidJS

/// opsCaching.ts. Sparse slots persist as JSON null; a duplicate stops the entire add operation.
public final class OpsCache {
    private struct Batch {
        var remaining: Int
        var data: [JSONValue]
        var dirty: Bool
    }
    private var batches: [Int: Batch] = [:]
    private var completed: Set<Int> = []
    private let batchSize: Int
    private var totalOpsToCache: Int
    public private(set) var persisted: [String: String] = [:]
    public init(startingSequenceNumber: Int, batchSize: Int = 100, totalOpsToCache: Int = 5000) {
        precondition(batchSize > 0)
        self.batchSize = batchSize
        self.totalOpsToCache = totalOpsToCache
        let remaining = batchSize - startingSequenceNumber % batchSize - 1
        if remaining != 0 { batches[startingSequenceNumber / batchSize] = Batch(remaining: remaining, data: Array(repeating: .null, count: batchSize), dirty: false) }
    }
    public func addOps(_ ops: [JSONValue]) throws {
        guard totalOpsToCache > 0 else { return }
        for op in ops {
            let seq = try op.member("sequenceNumber").asInt()
            let number = seq / batchSize
            let slot = seq % batchSize
            guard seq >= 0 else { throw JSONDecodingError("negative sequence") }
            if completed.contains(number) { return }
            var batch = batches[number] ?? Batch(remaining: batchSize, data: Array(repeating: .null, count: batchSize), dirty: false)
            if batch.data[slot] != .null { return }
            batch.data[slot] = op
            batch.remaining -= 1
            batch.dirty = true
            batches[number] = batch
            if batch.remaining == 0 {
                persisted["\(batchSize)_\(number)"] = JSON.stringify(.array(batch.data))
                batches.removeValue(forKey: number)
                completed.insert(number)
            }
            totalOpsToCache -= 1
            if totalOpsToCache == 0 {
                persisted.removeAll()
                dispose()
                break
            }
        }
    }
    public func flushOps() {
        for (number, var batch) in batches {
            guard batch.dirty, batch.data.first != .null || batch.data.last != .null else { continue }
            persisted["\(batchSize)_\(number)"] = JSON.stringify(.array(batch.data))
            batch.dirty = false
            batches[number] = batch
        }
    }
    public func dispose() {
        batches.removeAll()
        completed.removeAll()
    }
    public func get(from: Int, to: Int? = nil) throws -> [JSONValue] {
        var messages: [JSONValue] = []
        var number = from / batchSize
        while let raw = persisted["\(batchSize)_\(number)"] {
            let previous = messages.count
            for op in try JSON.parse(raw).asArray() {
                if op == .null {
                    if !messages.isEmpty { return messages }
                    continue
                }
                let seq = try op.member("sequenceNumber").asInt()
                if let to, seq >= to { return messages }
                if messages.isEmpty {
                    if seq > from { return messages }
                    if seq < from { continue }
                }
                messages.append(op)
            }
            if messages.count == previous { return messages }
            number += 1
        }
        return messages
    }
}
