import FluidJS
import FluidMergeTree
import FluidSharedObjectBase
import FluidDriverDefinitions

public protocol MatrixConsumer: AnyObject {
  func rowsChanged(_ start: Int, _ removed: Int, _ inserted: Int, _ matrix: SharedMatrix)
  func colsChanged(_ start: Int, _ removed: Int, _ inserted: Int, _ matrix: SharedMatrix)
  func cellsChanged(_ row: Int, _ col: Int, _ rows: Int, _ cols: Int, _ matrix: SharedMatrix)
}

public enum MatrixLocalOpMetadata {
  case vector(target: JSString, sequence: Int)
  case set(row: Int, col: Int, sequence: Int, rowsRef: LocalReference, colsRef: LocalReference, reference: Int)
}

/// Ports matrix/src/matrix.ts SharedMatrix. Storage coordinates are never wire coordinates.
public final class SharedMatrix: SharedObject<MatrixLocalOpMetadata> {
  public override class var type: JSString { "https://graph.microsoft.com/types/sharedmatrix" }
  public let rows = PermutationVector(id: "rows")
  public let cols = PermutationVector(id: "cols")
  private var cells = SparseArray2D()
  private var tracker = SparseArray2D()
  private struct CellKey: Hashable {
    let row: Int
    let col: Int
  }
  private struct Change {
    let sequence: Int
    let value: JSONValue?
  }
  private struct Pending {
    var consensus: JSONValue?
    var local: [Change]
  }
  private var pending: [CellKey: Pending] = [:]
  private var inFlight: [Int] = []
  private var regeneratedRows: [JSONValue] = []
  private var regeneratedCols: [JSONValue] = []
  private var resubmitting = false
  private var collaborationInitialized = false
  private var policyRequested = false
  private var switchSequence = -1
  private var editing = false
  private var consumers: [any MatrixConsumer] = []
  public var matrixProducer: SharedMatrix { self }
  @discardableResult
  public func openMatrix(_ consumer: any MatrixConsumer) -> SharedMatrix {
    if !consumers.contains(where: { $0 === consumer }) { consumers.append(consumer) }
    return self
  }
  public func closeMatrix(_ consumer: any MatrixConsumer) { consumers.removeAll { $0 === consumer } }
  public var event: ((JSONValue) -> Void)?
  public var rowCount: Int { rows.length }
  public var colCount: Int { cols.length }
  public required init(id: JSString) {
    super.init(id: id)
    rows.changed = { [weak self] start, removed, inserted in self?.structuralEvent("rowsChanged", start, removed, inserted) }
    cols.changed = { [weak self] start, removed, inserted in self?.structuralEvent("colsChanged", start, removed, inserted) }
    rows.recycled = { [weak self] handles in self?.recycle(handles, rows: true) }
    cols.recycled = { [weak self] handles in self?.recycle(handles, rows: false) }
  }
  private func recycle(_ handles: [Int], rows: Bool) {
    if rows {
      cells.clearRows(handles)
      tracker.clearRows(handles)
    } else {
      cells.clearCols(handles)
      tracker.clearCols(handles)
    }
    let set = Set(handles)
    pending = pending.filter { !set.contains(rows ? $0.key.row : $0.key.col) }
  }
  private func structuralEvent(_ name: JSString, _ start: Int, _ removed: Int, _ inserted: Int) {
    for consumer in consumers {
      if name == "rowsChanged" { consumer.rowsChanged(start, removed, inserted, self) }
      else { consumer.colsChanged(start, removed, inserted, self) }
    }
    event?(.array([.string(name), .number(Double(start)), .number(Double(removed)), .number(Double(inserted))]))
  }
  private func cellEvent(_ row: Int, _ col: Int) {
    for consumer in consumers { consumer.cellsChanged(row, col, 1, 1, self) }
    event?(.array([.string("cellsChanged"), .number(Double(row)), .number(Double(col)), .number(1), .number(1)]))
  }
  public func isSetCellConflictResolutionPolicyFWW() -> Bool { policyRequested || switchSequence != -1 }
  public func switchSetCellPolicy() {
    guard !isSetCellConflictResolutionPolicyFWW() else { return }
    policyRequested = true
    if !isAttached { switchSequence = 0 }
  }
  public override func didAttach() { onConnect() }
  public override func onConnect() {
    let id = runtime?.clientId ?? "attached"
    if !collaborationInitialized {
      rows.client.startOrUpdateCollaboration(id)
      cols.client.startOrUpdateCollaboration(id)
      collaborationInitialized = true
    }
    resubmitting = false
  }
  private func mutate(_ action: () throws -> Void) throws {
    try verifyOpen()
    guard !editing else { throw SharedObjectError("Reentrancy detected in SharedMatrix.") }
    editing = true
    defer { editing = false }
    try action()
  }
  private func syncSequences() {
    let sequence = max(rows.client.latestLocalSequence, cols.client.latestLocalSequence)
    while rows.client.latestLocalSequence < sequence { _ = rows.client.nextLocalSequence() }
    while cols.client.latestLocalSequence < sequence { _ = cols.client.nextLocalSequence() }
  }
  private func submit(_ op: JSONValue, _ metadata: MatrixLocalOpMetadata) throws {
    syncSequences()
    inFlight.append(runtime?.deltaManager.lastSequenceNumber ?? 0)
    try submitLocalMessage(op, metadata)
  }
  private func splice(_ vector: PermutationVector, target: JSString, start: Int, count: Int, insert: Bool) throws {
    if count == 0 { return }
    try mutate {
      guard start <= vector.length else { throw SharedObjectError("RangeOutOfBounds") }
      let op = insert ? matrixObject([("pos1", .number(Double(start))), ("seg", .array([.number(Double(count)), .number(Double(PermutationSegment.unallocated))])), ("type", .number(0))]) : matrixObject([("pos1", .number(Double(start))), ("pos2", .number(Double(start + count))), ("type", .number(1))])
      _ = try vector.client.edit(op)
      syncSequences()
      if isAttached {
        var fields = try op.asObject()
        fields["target"] = .string(target)
        try submit(.object(fields), .vector(target: target, sequence: vector.client.latestLocalSequence))
      }
    }
  }
  public func insertRows(_ start: Int, _ count: Int) throws { try splice(rows, target: "rows", start: start, count: count, insert: true) }
  public func insertCols(_ start: Int, _ count: Int) throws { try splice(cols, target: "cols", start: start, count: count, insert: true) }
  public func removeRows(_ start: Int, _ count: Int) throws { try splice(rows, target: "rows", start: start, count: count, insert: false) }
  public func removeCols(_ start: Int, _ count: Int) throws { try splice(cols, target: "cols", start: start, count: count, insert: false) }
  public func getCell(_ row: Int, _ col: Int) throws -> JSONValue? {
    let r = try rows.maybeHandle(row)
    let c = try cols.maybeHandle(col)
    return r >= 1 && c >= 1 ? cells.getCell(r, c) : nil
  }
  public func setCell(_ row: Int, _ col: Int, _ value: JSONValue?) throws {
    guard row >= 0, row < rowCount, col >= 0, col < colCount else { throw SharedObjectError("RangeOutOfBounds") }
    let r = try rows.allocatedHandle(row)
    let c = try cols.allocatedHandle(col)
    try mutate {
      let key = CellKey(row: r, col: c)
      let previous = cells.getCell(r, c)
      cells.setCell(r, c, value)
      if isAttached {
        _ = cols.client.nextLocalSequence()
        let sequence = rows.client.nextLocalSequence()
        try sendSet(row, col, value, key: key, sequence: sequence)
        if pending[key]?.local.count == 1 && (pending[key]?.consensus == nil || pending[key]?.consensus == .null) {
          pending[key]?.consensus = previous == .null ? nil : previous
        }
      }
      cellEvent(row, col)
    }
  }
  public func setCells(_ rowStart: Int, _ colStart: Int, _ colCount: Int, _ values: [JSONValue?]) throws {
    guard rowStart >= 0, rowStart < rowCount, colStart >= 0, colStart < self.colCount,
      colCount >= 1, colCount <= self.colCount - colStart,
      (values.count + colCount - 1) / colCount <= rowCount - rowStart else {
      throw SharedObjectError("setCells range out of bounds")
    }
    for (index, value) in values.enumerated() {
      try setCell(rowStart + index / colCount, colStart + index % colCount, value)
    }
  }
  private func sendSet(_ row: Int, _ col: Int, _ value: JSONValue?, key: CellKey, sequence: Int) throws {
    var fields = JSObject<JSONValue>()
    fields["type"] = .number(2)
    fields["row"] = .number(Double(row))
    fields["col"] = .number(Double(col))
    fields["value"] = value
    fields["fwwMode"] = .bool(isSetCellConflictResolutionPolicyFWW())
    let r = try rows.client.createLocalReferencePosition(at: row, refType: 128, perspective: .reconnecting(sequence: rows.client.currentSequence, localSequence: sequence))
    let c = try cols.client.createLocalReferencePosition(at: col, refType: 128, perspective: .reconnecting(sequence: cols.client.currentSequence, localSequence: sequence))
    try submit(.object(fields), .set(row: key.row, col: key.col, sequence: sequence, rowsRef: r, colsRef: c, reference: runtime?.deltaManager.lastSequenceNumber ?? 0))
    pending[key, default: Pending(consensus: nil, local: [])].local.append(Change(sequence: sequence, value: value))
  }
  private func accepts(_ key: CellKey, _ message: SequencedMessage) throws -> Bool {
    guard let previous = tracker.getCell(key.row, key.col) else { return true }
    return try previous.member("clientId") == .string(message.clientId) || message.referenceSequenceNumber >= previous.member("seqNum").asInt()
  }
  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      let message = content.message
      let fields = try message.contents.asObject()
      if local {
        guard !inFlight.isEmpty else { throw SharedObjectError("0x8ba missing pending reference") }
        inFlight.removeFirst()
      }
      if let target = fields["target"] {
        guard target == .string("rows") || target == .string("cols") else { throw SharedObjectError("unknown matrix target") }
        let vector = target == .string("rows") ? rows : cols
        try vector.client.process(message.contents, sender: local ? vector.client.id : message.clientId, sequence: message.sequenceNumber, referenceSequence: message.referenceSequenceNumber)
        try vector.client.advanceMinimum(to: min(message.minimumSequenceNumber, inFlight.min() ?? message.minimumSequenceNumber))
        continue
      }
      guard fields["type"] == .number(2) else { throw SharedObjectError("invalid matrix op") }
      if fields["fwwMode"] == .bool(true) && switchSequence == -1 {
        switchSequence = message.sequenceNumber
        policyRequested = true
        tracker = SparseArray2D()
      }
      let value = fields["value"]
      let key: CellKey
      if local {
        guard case .set(let row, let col, let sequence, let r, let c, _) = content.metadata else { throw SharedObjectError("missing set metadata") }
        _ = rows.client.removeLocalReferencePosition(r)
        _ = cols.client.removeLocalReferencePosition(c)
        key = CellKey(row: row, col: col)
        guard var p = pending[key], p.local.first?.sequence == sequence else { throw SharedObjectError("0xbab pending set mismatch") }
        let acked = p.local.removeFirst()
        if try switchSequence != -1 && accepts(key, message) {
          p.consensus = acked.value
          tracker.setCell(row, col, matrixObject([("seqNum", .number(Double(message.sequenceNumber))), ("clientId", .string(message.clientId))]))
        }
        pending[key] = p.local.isEmpty ? nil : p
      } else {
        let row = try message.contents.member("row").asInt()
        let col = try message.contents.member("col").asInt()
        let r = try rows.adjust(row, sequence: message.referenceSequenceNumber, sender: message.clientId)
        let c = try cols.adjust(col, sequence: message.referenceSequenceNumber, sender: message.clientId)
        key = CellKey(row: r.handle, col: c.handle)
        if switchSequence != -1 {
          if try accepts(key, message) {
            let old = cells.getCell(key.row, key.col)
            cells.setCell(key.row, key.col, value)
            tracker.setCell(key.row, key.col, matrixObject([("seqNum", .number(Double(message.sequenceNumber))), ("clientId", .string(message.clientId))]))
            if pending[key] != nil { pending[key]?.consensus = value }
            if let rp = r.position, let cp = c.position {
              cellEvent(rp, cp)
              if pending[key]?.local.isEmpty == false {
                event?(.array([.string("conflict"), .number(Double(row)), .number(Double(col)), canonical(value), canonical(old)]))
              }
            }
          }
        } else if pending[key]?.local.isEmpty != false {
          cells.setCell(key.row, key.col, value)
          if let rp = r.position, let cp = c.position { cellEvent(rp, cp) }
        } else { pending[key]?.consensus = value }
      }
    }
  }
  private func canonical(_ value: JSONValue?) -> JSONValue { value ?? matrixObject([("$fluid", .string("undefined"))]) }
  public override func reSubmitCore(_ content: JSONValue, localOpMetadata metadata: MatrixLocalOpMetadata) throws {
    if !resubmitting {
      regeneratedRows = try rows.client.regeneratePendingOps()
      regeneratedCols = try cols.client.regeneratePendingOps()
      resubmitting = true
    }
    guard !inFlight.isEmpty else { throw SharedObjectError("missing resubmit reference") }
    inFlight.removeFirst()
    switch metadata {
    case .vector(let target, _):
      let op: JSONValue
      if target == "rows" {
        guard !regeneratedRows.isEmpty else { throw SharedObjectError("missing regenerated row op") }
        op = regeneratedRows.removeFirst()
      } else {
        guard !regeneratedCols.isEmpty else { throw SharedObjectError("missing regenerated col op") }
        op = regeneratedCols.removeFirst()
      }
      var fields = try op.asObject()
      fields["target"] = .string(target)
      try submit(.object(fields), metadata)
    case .set(let row, let col, let sequence, let r, let c, let reference):
      let key = CellKey(row: row, col: col)
      guard pending[key]?.local.contains(where: { $0.sequence == sequence }) == true else { throw SharedObjectError("missing pending resubmit cell") }
      pending[key]?.local.removeAll { $0.sequence == sequence }
      defer {
        _ = rows.client.removeLocalReferencePosition(r)
        _ = cols.client.removeLocalReferencePosition(c)
      }
      guard let rs = r.segment, let cs = c.segment, rs.removals.isEmpty, cs.removals.isEmpty else { return }
      let rp = rows.client.position(rs, perspective: .reconnecting(sequence: rows.client.currentSequence, localSequence: sequence)) + r.offset
      let cp = cols.client.position(cs, perspective: .reconnecting(sequence: cols.client.currentSequence, localSequence: sequence)) + c.offset
      if let last = tracker.getCell(row, col), switchSequence != -1, reference < (try last.member("seqNum").asInt()) { return }
      try sendSet(rp, cp, try content.asObject()["value"], key: key, sequence: sequence)
    }
  }
  public override func rollback(_ content: JSONValue, localOpMetadata: MatrixLocalOpMetadata) throws {
    switch localOpMetadata {
    case .vector(let target, _): try (target == "rows" ? rows : cols).client.rollbackPendingOp()
    case .set(let row, let col, let sequence, _, _, _):
      let key = CellKey(row: row, col: col)
      guard var p = pending[key], p.local.last?.sequence == sequence else { throw SharedObjectError("0xbaa rollback mismatch") }
      p.local.removeLast()
      let previous = p.local.last.map { $0.value } ?? p.consensus
      pending[key] = p
      cells.setCell(row, col, previous)
      cellEvent(try content.member("row").asInt(), try content.member("col").asInt())
    }
  }
  public override func applyStashedOp(_ content: JSONValue) throws {
    let fields = try content.asObject()
    if let target = fields["target"] {
      let vector = target == .string("rows") ? rows : cols
      try vector.client.applyStashedOp(content)
      try submit(content, .vector(target: try target.asString(), sequence: vector.client.latestLocalSequence))
    } else {
      if fields["fwwMode"] == .bool(true) { switchSetCellPolicy() }
      try setCell(content.member("row").asInt(), content.member("col").asInt(), fields["value"])
    }
  }
  public override func summarize() -> SummaryTree {
    do { return try matrixSummary() }
    catch { preconditionFailure("invalid matrix summary: \(error)") }
  }
  public func matrixSummary() throws -> SummaryTree {
    let sequence = runtime?.deltaManager.lastSequenceNumber ?? 0
    let minimum = runtime?.deltaManager.minimumSequenceNumber ?? 0
    let rowSnapshot = try rows.snapshot(minimum: minimum, sequence: sequence, wireId: runtime?.clientId)
    let colSnapshot = try cols.snapshot(minimum: minimum, sequence: sequence, wireId: runtime?.clientId)
    var data: [JSONValue] = [cells.snapshot, .array([.null]), .number(Double(switchSequence))]
    if switchSequence != -1 { data.append(tracker.snapshot) }
    return try SummaryTree(json: matrixObject([("type", .number(1)), ("tree", matrixObject([
      ("rows", rowSnapshot),
      ("cols", colSnapshot),
      ("cells", matrixBlob(.array(data))),
    ]))]))
  }
  public override func loadCore(_ summary: SummaryTree) throws {
    let tree = try summary.json.member("tree")
    try rows.load(tree.member("rows"))
    try cols.load(tree.member("cols"))
    let data = try JSON.parse(tree.member("cells").member("content").asString().description).asArray()
    guard data.count >= 2 else { throw JSONDecodingError("invalid matrix cells snapshot") }
    cells = try SparseArray2D(snapshot: data[0])
    if data.count > 2 && data[2] != .null {
      switchSequence = try data[2].asInt()
      if switchSequence != -1 {
        guard data.count > 3 else { throw JSONDecodingError("missing FWW tracker") }
        tracker = try SparseArray2D(snapshot: data[3])
      }
    }
  }
}
