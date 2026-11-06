import FluidJS

/// Sequenced prefix sums plus sparse per-client corrections. Storage scales with
/// edit boundaries, not document characters. Query is two binary searches.
public struct PartialLengths: Sendable {
  private struct Entry: Sendable {
    var sequence: Int
    var length: Int
  }
  private struct Series: Sendable {
    var baseline = 0
    var entries: ContiguousArray<Entry> = []
    init(deltas: [Int: Int], minimum: Int) {
      var length = 0
      for sequence in deltas.keys.sorted() {
        length += deltas[sequence, default: 0]
        if sequence <= minimum {
          baseline = length
        } else {
          entries.append(Entry(sequence: sequence, length: length))
        }
      }
    }
    func value(at sequence: Int) -> Int {
      var low = 0
      var high = entries.count
      while low < high {
        let mid = (low + high) / 2
        if entries[mid].sequence <= sequence { low = mid + 1 } else { high = mid }
      }
      return low == 0 ? baseline : entries[low - 1].length
    }
    mutating func collapse(to sequence: Int) {
      baseline = value(at: sequence)
      entries.removeAll { $0.sequence <= sequence }
    }
  }
  private var global: Series
  private var clients: [JSString: Series] = [:]
  public private(set) var minimumSequence: Int

  public init(segments: [BaseSegment], minimumSequence: Int) {
    self.minimumSequence = minimumSequence
    var deltas: [Int: Int] = [:]
    var corrections: [JSString: [Int: Int]] = [:]
    for segment in segments {
      let start = segment.insertion.sequence == -1 ? Int.max : segment.insertion.sequence
      let end = segment.removals.lazy.filter { $0.sequence != -1 }.map(\.sequence).min() ?? Int.max
      if start < end {
        deltas[start, default: 0] += segment.length
        if end != Int.max { deltas[end, default: 0] -= segment.length }
      }
      let affected = Set([segment.insertion.client] + segment.removals.map(\.client))
      for client in affected {
        let ownStart = segment.insertion.client == client ? 0 : start
        let ownEnd = segment.removals.contains { $0.client == client } ? 0 : end
        var delta = corrections[client, default: [:]]
        if start < end {
          delta[start, default: 0] -= segment.length
          if end != Int.max { delta[end, default: 0] += segment.length }
        }
        if ownStart < ownEnd {
          delta[ownStart, default: 0] += segment.length
          if ownEnd != Int.max { delta[ownEnd, default: 0] -= segment.length }
        }
        corrections[client] = delta
      }
    }
    global = Series(deltas: deltas, minimum: minimumSequence)
    clients = corrections.mapValues { Series(deltas: $0, minimum: minimumSequence) }
  }
  public func length(sequence: Int, client: JSString) -> Int {
    precondition(sequence >= minimumSequence)
    return global.value(at: sequence) + (clients[client]?.value(at: sequence) ?? 0)
  }
  public mutating func advanceMinimum(to sequence: Int) {
    precondition(sequence >= minimumSequence)
    minimumSequence = sequence
    global.collapse(to: sequence)
    for key in Array(clients.keys) { clients[key]?.collapse(to: sequence) }
  }
}
