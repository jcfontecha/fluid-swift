import FluidDriverDefinitions
import FluidDriverUtils
import FluidJS

/// Typed driver boundary over the shared driver-utils requestOps implementation.
public func requestOps(
    _ get: @escaping @Sendable (Int, Int) async throws -> IDeltasFetchResult,
    fromTotal: Int, toTotal: Int?, payloadSize: Int
) -> AsyncThrowingStream<[ISequencedDocumentMessage], any Error> {
    let batches = FluidDriverUtils.requestOps(concurrency: 1, fromTotal: fromTotal, toTotal: toTotal, payloadSize: payloadSize) { from, to in
        let result = try await get(from, to)
        return (result.messages.map(\.json), result.partialResult)
    }
    let (stream, continuation) = AsyncThrowingStream<[ISequencedDocumentMessage], any Error>.makeStream()
    let task = Task {
        do {
            for try await batch in batches {
                continuation.yield(try batch.map { try ISequencedDocumentMessage(json: $0) })
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}
