import Testing
import FluidJS
@testable import FluidMatrix

/// Ports matrix/src/test/sparsearray2d.spec.ts and matrix.spec.ts.
struct MatrixTests {
  @Test func handlesRecycleLIFO() {
    let table = HandleTable()
    #expect(table.allocate() == 1)
    #expect(table.allocate() == 2)
    table.free(1)
    #expect(table.allocate() == 1)
    #expect(table.summary == [3, 0, 0])
  }

  @Test func sparseStorageAndClearing() throws {
    let cells = SparseArray2D()
    #expect(cells.getCell(1, 1) == nil)
    cells.setCell(1, 1, .number(7))
    cells.setCell(65537, 65538, .string("high"))
    #expect(cells.getCell(1, 1) == .number(7))
    #expect(cells.getCell(65537, 65538) == .string("high"))
    let loaded = try SparseArray2D(snapshot: cells.snapshot)
    #expect(loaded.getCell(65537, 65538) == .string("high"))
    cells.clearRows([1])
    #expect(cells.getCell(1, 1) == nil)
    #expect(cells.getCell(65537, 65538) == .string("high"))
  }

  @Test func structurePreservesCells() throws {
    let matrix = SharedMatrix(id: "matrix")
    try matrix.insertRows(0, 3)
    try matrix.insertCols(0, 3)
    try matrix.setCell(1, 1, .string("center"))
    try matrix.insertRows(0, 2)
    try matrix.insertCols(0, 1)
    #expect(try matrix.getCell(3, 2) == .string("center"))
    try matrix.removeRows(0, 2)
    #expect(try matrix.getCell(1, 2) == .string("center"))
    try matrix.setCell(1, 2, nil)
    #expect(try matrix.getCell(1, 2) == nil)
  }

  @Test func boundsAndEmptyOperations() throws {
    let matrix = SharedMatrix(id: "matrix")
    try matrix.insertRows(100, 0)
    #expect(throws: (any Error).self) { try matrix.setCell(0, 0, .number(1)) }
    #expect(throws: (any Error).self) { try matrix.getCell(0, 0) }
  }

  @Test func detachedPolicyAndSummary() throws {
    let matrix = SharedMatrix(id: "matrix")
    #expect(!matrix.isSetCellConflictResolutionPolicyFWW())
    matrix.switchSetCellPolicy()
    #expect(matrix.isSetCellConflictResolutionPolicyFWW())
    #expect(try matrix.summarize().json.member("tree").member("cells").member("content") == .string("[[null],[null],0,[null]]"))
    try matrix.insertRows(0, 1)
    try matrix.insertCols(0, 1)
    try matrix.setCell(0, 0, .number(42))
    let loaded = try SharedMatrix.load(id: "copy", summary: matrix.summarize())
    #expect(try loaded.getCell(0, 0) == .number(42))
  }
  @Test func bulkWritesAreRowMajorAndValidateEmptyRanges() throws {
    let matrix = SharedMatrix(id: "matrix")
    try matrix.insertRows(0, 3)
    try matrix.insertCols(0, 4)
    try matrix.setCells(1, 1, 2, [.number(1), nil, .number(3)])
    #expect(try matrix.getCell(1, 1) == .number(1))
    #expect(try matrix.getCell(1, 2) == nil)
    #expect(try matrix.getCell(2, 1) == .number(3))
    #expect(throws: (any Error).self) { try matrix.setCells(3, 0, 1, []) }
    #expect(throws: (any Error).self) { try matrix.setCells(0, 0, 0, []) }
    #expect(throws: (any Error).self) { try matrix.setCells(2, 3, 1, [.number(1), .number(2)]) }
  }

  @Test func consumersHaveSetIdentityAndLocalEditsRejectReentrancy() throws {
    let matrix = SharedMatrix(id: "matrix")
    let observer = Observer()
    matrix.openMatrix(observer)
    matrix.openMatrix(observer)
    #expect(observer.notifications == 0)
    try matrix.insertRows(0, 1)
    try matrix.insertCols(0, 1)
    #expect(observer.notifications == 2)
    observer.onCell = { matrix in
      #expect(throws: (any Error).self) { try matrix.setCell(0, 0, .number(9)) }
      #expect(throws: (any Error).self) { try matrix.insertRows(0, 1) }
      #expect(throws: Never.self) { try matrix.insertRows(100, 0) }
    }
    try matrix.setCell(0, 0, .number(1))
    #expect(observer.notifications == 3)
    #expect(try matrix.getCell(0, 0) == .number(1))
    matrix.closeMatrix(observer)
    try matrix.setCell(0, 0, .number(2))
    #expect(observer.notifications == 3)
  }

  @Test func largeEmptyDimensionsRemainSegmentSpans() throws {
    let matrix = SharedMatrix(id: "matrix")
    try matrix.insertRows(0, 1_000_000)
    try matrix.insertCols(0, 1_000_000)
    #expect(matrix.rowCount == 1_000_000)
    #expect(matrix.rows.client.segments.count == 1)
    #expect(matrix.cols.client.segments.count == 1)
    try matrix.setCell(999_999, 999_999, .number(7))
    #expect(matrix.rows.client.segments.count == 2)
    #expect(matrix.cols.client.segments.count == 2)
  }

  @Test func sparseClearsMatchFullCoordinatesAcrossTiles() {
    let cells = SparseArray2D()
    let positions = [1, 16, 255, 65535, 65536, 65537]
    for row in positions {
      for col in positions { cells.setCell(row, col, .number(Double(row + col))) }
    }
    cells.clearRows([16, 65536])
    cells.clearCols([255, 65537])
    for row in positions {
      for col in positions {
        let removed = row == 16 || row == 65536 || col == 255 || col == 65537
        #expect(cells.getCell(row, col) == (removed ? nil : .number(Double(row + col))))
      }
    }
  }

  @Test func groupedStashRegeneratesAndAcknowledgesAsOneMessage() throws {
    let vector = PermutationVector(id: "client")
    vector.client.startOrUpdateCollaboration("client")
    let inserts = try JSON.parse("{\"ops\":[{\"pos1\":0,\"seg\":[1,-2147483648],\"type\":0},{\"pos1\":1,\"seg\":[1,-2147483648],\"type\":0}],\"type\":3}")
    try vector.client.applyStashedOp(inserts)
    #expect(vector.client.pendingOperationCount == 1)
    #expect(vector.client.latestLocalSequence == 2)
    let regenerated = try vector.client.regeneratePendingOps()
    #expect(regenerated.count == 1)
    try vector.client.process(regenerated[0], sender: "client", sequence: 1, referenceSequence: 0)
    #expect(vector.client.pendingOperationCount == 0)
    #expect(vector.length == 2)
    let mixed = try JSON.parse("{\"ops\":[{\"pos1\":0,\"seg\":[1,-2147483648],\"type\":0},{\"pos1\":1,\"pos2\":2,\"type\":1}],\"type\":3}")
    try vector.client.applyStashedOp(mixed)
    try vector.client.rollbackPendingOp()
    #expect(vector.client.pendingOperationCount == 0)
    #expect(vector.length == 2)
  }

  @Test func sparseSummaryRetainsAllocatedArraysAfterClear() throws {
    let cells = SparseArray2D()
    cells.setCell(1, 1, .number(7))
    let root = try cells.snapshot.asArray()
    #expect(root.count == 1)
    var level = root[0]
    for _ in 0..<3 {
      let array = try level.asArray()
      #expect(array.count == 256)
      level = array[0]
    }
    #expect(try level.asArray()[3] == .number(7))
    cells.setCell(1, 1, nil)
    #expect(try cells.snapshot.asArray()[0].asArray().count == 256)
  }

}

private final class Observer: MatrixConsumer {
  var notifications = 0
  var onCell: ((SharedMatrix) -> Void)?
  func rowsChanged(_ start: Int, _ removed: Int, _ inserted: Int, _ matrix: SharedMatrix) { notifications += 1 }
  func colsChanged(_ start: Int, _ removed: Int, _ inserted: Int, _ matrix: SharedMatrix) { notifications += 1 }
  func cellsChanged(_ row: Int, _ col: Int, _ rows: Int, _ cols: Int, _ matrix: SharedMatrix) {
    notifications += 1
    onCell?(matrix)
  }
}
