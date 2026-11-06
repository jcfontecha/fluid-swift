import FluidJS

/// Sequenced prefix sums plus sparse per-client corrections. Storage scales with
/// edit boundaries, not document characters. Query is two binary searches.
public struct PartialSequenceLengths: Sendable {
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
    mutating func add(_ other: Series, scale: Int, minimum: Int) {
      apply(other.baseline * scale, at: minimum, minimum: minimum)
      var previous = other.baseline
      for entry in other.entries {
        apply((entry.length - previous) * scale, at: entry.sequence, minimum: minimum)
        previous = entry.length
      }
    }
    private mutating func apply(_ delta: Int, at sequence: Int, minimum: Int) {
      guard delta != 0 else { return }
      if sequence <= minimum {
        baseline += delta
        for index in entries.indices { entries[index].length += delta }
        return
      }
      var low = 0
      var high = entries.count
      while low < high {
        let mid = (low + high) / 2
        if entries[mid].sequence < sequence { low = mid + 1 } else { high = mid }
      }
      if low == entries.count || entries[low].sequence != sequence {
        let previous = low == 0 ? baseline : entries[low - 1].length
        entries.insert(Entry(sequence: sequence, length: previous), at: low)
      }
      for index in low..<entries.count { entries[index].length += delta }
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
  private var reconnecting = Series(deltas: [:], minimum: -1)
  private var latestSequence = 0
  private var clients: [JSString: Series] = [:]
  public private(set) var minimumSequence: Int

  public init(segments: [BaseSegment], minimumSequence: Int) {
    self.minimumSequence = minimumSequence
    var deltas: [Int: Int] = [:]
    var localDeltas: [Int: Int] = [:]
    var corrections: [JSString: [Int: Int]] = [:]
    for segment in segments {
      let start = segment.insertion.sequence == -1 ? Int.max : segment.insertion.sequence
      let end = segment.removals.lazy.filter { $0.sequence != -1 }.map(\.sequence).min() ?? Int.max
      if start < end {
        deltas[start, default: 0] += segment.length
        if end != Int.max { deltas[end, default: 0] -= segment.length }
      }
      latestSequence = max(
        latestSequence, segment.insertion.sequence,
        segment.removals.map(\.sequence).max() ?? 0)
      if end == Int.max {
        let localEnd = segment.removals.compactMap(\.localSequence).min() ?? Int.max
        if segment.insertion.sequence == -1 {
          let localStart = segment.insertion.localSequence ?? Int.max
          if localStart < localEnd {
            localDeltas[localStart, default: 0] += segment.length
            if localEnd != Int.max { localDeltas[localEnd, default: 0] -= segment.length }
          }
        } else if localEnd != Int.max {
          localDeltas[localEnd, default: 0] -= segment.length
        }
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
    reconnecting = Series(deltas: localDeltas, minimum: -1)
    clients = corrections.mapValues { Series(deltas: $0, minimum: minimumSequence) }
  }
  mutating func add(_ other: PartialSequenceLengths, scale: Int = 1) {
    let minimum = max(minimumSequence, other.minimumSequence)
    if minimumSequence < minimum { advanceMinimum(to: minimum) }
    // Series.apply folds entries at/below the minimum into the baseline directly.
    // Do not copy and collapse every source client series merely to add it.
    global.add(other.global, scale: scale, minimum: minimumSequence)
    reconnecting.add(other.reconnecting, scale: scale, minimum: -1)
    latestSequence = max(latestSequence, other.latestSequence)
    for (client, series) in other.clients {
      clients[client, default: Series(deltas: [:], minimum: minimumSequence)]
        .add(series, scale: scale, minimum: minimumSequence)
    }
  }
  /// Current-ref reconnect queries combine acknowledged length with local-seq
  /// deltas. An older ref can hide an insertion beneath a pending removal, so
  /// that genuinely two-dimensional historical query uses the tree perspective.
  public func reconnectingLength(sequence: Int, localSequence: Int) -> Int? {
    guard sequence >= latestSequence else { return nil }
    return global.value(at: sequence) + reconnecting.value(at: localSequence)
  }

  public func length(sequence: Int, client: JSString) -> Int {
    precondition(sequence >= minimumSequence)
    return global.value(at: sequence) + (clients[client]?.value(at: sequence) ?? 0)
  }
  public mutating func advanceMinimum(to sequence: Int) {
    precondition(sequence >= minimumSequence)
    minimumSequence = sequence
    global.collapse(to: sequence)
    for key in Array(clients.keys) {
      clients[key]?.collapse(to: sequence)
      if let series = clients[key], series.baseline == 0, series.entries.isEmpty {
        clients.removeValue(forKey: key)
      }
    }
  }
}
