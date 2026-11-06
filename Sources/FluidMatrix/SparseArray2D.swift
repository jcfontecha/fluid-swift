import FluidJS

/// Ports matrix/src/sparsearray2d.ts. Sparse branches retain array lengths after clearing;
/// leaf tiles use contiguous values rather than a heap object for each occupied cell.
public final class SparseArray2D {
  private final class Node {
    var length: Int
    var children: [Int: Node] = [:]
    var values: ContiguousArray<JSONValue?> = []
    init(length: Int, leaf: Bool = false) {
      self.length = length
      if leaf { values = ContiguousArray(repeating: nil, count: length) }
    }
    func json(depth: Int) -> JSONValue {
      if depth == 4 { return .array(values.map { $0 ?? .null }) }
      return .array((0..<length).map { children[$0]?.json(depth: depth + 1) ?? .null })
    }
  }
  private var root = Node(length: 1)
  public init() {}
  public convenience init(snapshot: JSONValue) throws {
    self.init()
    func load(_ value: JSONValue, depth: Int) throws -> Node {
      let array = try value.asArray()
      let node = Node(length: array.count, leaf: depth == 4)
      if depth == 4 {
        node.values = ContiguousArray(array.map { $0 == .null ? nil : $0 })
      } else {
        for (index, child) in array.enumerated() where child != .null {
          node.children[index] = try load(child, depth: depth + 1)
        }
      }
      return node
    }
    root = try load(snapshot, depth: 0)
  }
  private func morton(_ row: UInt32, _ col: UInt32) -> UInt32 {
    func spread(_ value: UInt32) -> UInt32 {
      var bits = value & 0xffff
      bits = (bits | (bits << 8)) & 0x00ff00ff
      bits = (bits | (bits << 4)) & 0x0f0f0f0f
      bits = (bits | (bits << 2)) & 0x33333333
      return (bits | (bits << 1)) & 0x55555555
    }
    return (spread(row) << 1) | spread(col)
  }
  private func path(_ row: Int, _ col: Int) -> [Int] {
    let r = UInt32(truncatingIfNeeded: row)
    let c = UInt32(truncatingIfNeeded: col)
    let low = morton(r, c)
    return [Int(morton(r >> 16, c >> 16)), Int(low >> 24), Int((low >> 16) & 255), Int((low >> 8) & 255), Int(low & 255)]
  }
  public func getCell(_ row: Int, _ col: Int) -> JSONValue? {
    let indices = path(row, col)
    var node = root
    for index in indices.prefix(4) {
      guard let next = node.children[index] else { return nil }
      node = next
    }
    return indices[4] < node.values.count ? node.values[indices[4]] : nil
  }
  public func setCell(_ row: Int, _ col: Int, _ value: JSONValue?) {
    let indices = path(row, col)
    var node = root
    for (depth, index) in indices.prefix(4).enumerated() {
      node.length = max(node.length, index + 1)
      if node.children[index] == nil { node.children[index] = Node(length: 256, leaf: depth == 3) }
      guard let next = node.children[index] else { preconditionFailure("missing newly created sparse node") }
      node = next
    }
    if indices[4] >= node.values.count { node.values.append(contentsOf: repeatElement(nil, count: indices[4] + 1 - node.values.count)) }
    node.values[indices[4]] = value
  }
  public var snapshot: JSONValue { root.json(depth: 0) }
  private func clear(_ handles: [Int], rows: Bool) {
    guard !handles.isEmpty else { return }
    let patterns = Set(handles.map { handle -> UInt64 in
      let value = UInt32(truncatingIfNeeded: handle)
      let high = rows ? morton(value >> 16, 0) : morton(0, value >> 16)
      let low = rows ? morton(value, 0) : morton(0, value)
      return (UInt64(high) << 32) | UInt64(low)
    })
    let mask: UInt64 = rows ? 0xaaaaaaaaaaaaaaaa : 0x5555555555555555
    func visit(_ node: Node, depth: Int, indices: [Int]) {
      if depth == 4 {
        let prefix = UInt32(indices[1]) << 24 | UInt32(indices[2]) << 16 | UInt32(indices[3]) << 8
        let high = UInt64(indices[0]) << 32
        for index in node.values.indices where node.values[index] != nil {
          let address = high | UInt64(prefix | UInt32(index))
          if patterns.contains(address & mask) { node.values[index] = nil }
        }
        return
      }
      for (index, child) in node.children { visit(child, depth: depth + 1, indices: indices + [index]) }
    }
    visit(root, depth: 0, indices: [])
  }
  public func clearRows(_ handles: [Int]) { clear(handles, rows: true) }
  public func clearCols(_ handles: [Int]) { clear(handles, rows: false) }
}
