import FluidJS
import Foundation

/// Ports blobManager/blobManager.ts BlobHandle. Graph attachment and payload sharing are independent.
public final class BlobHandle {
  public let path: JSString
  public var absolutePath: JSString { path }
  public typealias ReadCompletion = (Result<[UInt8], any Error>) throws -> Void
  public let get: (@escaping ReadCompletion) throws -> Void
  public let payloadPending: Bool
  public private(set) var payloadState: String
  public private(set) var payloadShareError: (any Error)?
  public var routeAttached: () -> Bool = { true }
  public var onShared: () throws -> Void = {}
  public var onFailed: (any Error) throws -> Void = { _ in }
  private var attached = false
  private var sharingStarted = false
  private let share: () throws -> Void
  private let attach: () throws -> Void
  public var isAttached: Bool { routeAttached() && attached }
  public init(path: JSString, payloadPending: Bool, get: @escaping (@escaping ReadCompletion) throws -> Void = { _ in throw JSONDecodingError("blob reader not configured") }, share: @escaping () throws -> Void = {}, attach: @escaping () throws -> Void = {}) {
    self.path = path
    self.get = get
    self.payloadPending = payloadPending
    payloadState = payloadPending ? "pending" : "shared"
    self.share = share
    self.attach = attach
  }
  public func sharePayload() throws {
    if payloadState == "shared" || sharingStarted { return }
    sharingStarted = true
    try share()
  }
  public func attachGraph() throws {
    if attached { return }
    attached = true
    try attach()
    try sharePayload()
  }
  public func notifyShared() throws {
    payloadState = "shared"
    try onShared()
  }
  public func notifyFailed(_ error: any Error) throws {
    payloadShareError = error
    try onFailed(error)
  }
}

/// Ports blobManager/blobManager.ts. All storage completions must re-enter the container executor.
/// Upload/read callbacks are the I/O edge; mutation, op processing and event delivery stay synchronous.
public final class BlobManager {
  public enum AttachState { case detached, attaching, attached }
  public struct UploadResponse {
    public let id: JSString
    public let minTTLInSeconds: Double?
    public init(id: JSString, minTTLInSeconds: Double? = nil) {
      self.id = id
      self.minTTLInSeconds = minTTLInSeconds
    }
  }
  private struct Record {
    var state: String
    var bytes: [UInt8]
    var storageId: JSString?
    var uploadTime: Double?
    var ttl: Double?
  }
  public var attachState: AttachState = .attached
  public var generateUUID: () -> JSString = { JSString(UUID().uuidString.lowercased()) }
  public var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
  public var upload: ([UInt8], @escaping (Result<UploadResponse, any Error>) throws -> Void) throws -> Void = { _, _ in throw JSONDecodingError("storage not configured") }
  public var read: (JSString, @escaping (Result<[UInt8], any Error>) throws -> Void) throws -> Void = { _, _ in throw JSONDecodingError("storage not configured") }
  public var sendBlobAttachMessage: (JSONValue) throws -> Void = { _ in }
  public var blobRequested: (JSString) throws -> Void = { _ in }
  public var isBlobDeleted: (JSString) -> Bool = { _ in false }
  public var outstandingBlobWorkChanged: () throws -> Void = {}
  private var waitingForAttached: [() throws -> Void] = []
  private var redirects = JSMap<JSString, JSString>()
  private var cache: [JSString: Record] = [:]
  private var pending: [JSString] = []
  private var pendingOnly: [JSString] = []
  private var unshared: Set<JSString> = []
  private var handles: [JSString: BlobHandle] = [:]
  private var legacyCompletions: [JSString: (BlobHandle) throws -> Void] = [:]
  private var waitingReads: [JSString: [(Result<[UInt8], any Error>) throws -> Void]] = [:]
  public var hasOutstandingBlobWork: Bool { !unshared.isEmpty }
  public var unsharedBlobCount: Int { unshared.count }
  public init() {}
  private func track(_ id: JSString, start: Bool) throws {
    let before = hasOutstandingBlobWork
    if start { unshared.insert(id) } else { unshared.remove(id) }
    if before != hasOutstandingBlobWork { try outstandingBlobWorkChanged() }
  }
  public func setAttachState(_ state: AttachState) throws {
    attachState = state
    if state == .attached {
      let waiting = waitingForAttached
      waitingForAttached.removeAll()
      for create in waiting { try create() }
    }
  }
  public func hasBlob(_ id: JSString) -> Bool { cache[id] != nil || redirects.has(id) }
  public func lookupTemporaryBlobStorageId(_ id: JSString) -> JSString? {
    attachState == .detached ? nil : redirects.get(id)
  }
  public func load(ids: [JSString], redirectTable: [(JSString, JSString)]) {
    redirects = toRedirectTable(BlobManagerLoadInfo(ids: ids, redirectTable: redirectTable))
  }
  public func restorePendingBlobs(_ state: JSONValue?) throws {
    guard let state else { return }
    for (id, value) in try state.asObject().entries {
      try require(!redirects.has(id), "0xc7e")
      guard let bytes = try Data(base64Encoded: value.member("blob").asString().description) else { throw JSONDecodingError("invalid base64") }
      let state = try value.member("state").asString().description
      try require(state == "localOnly" || state == "uploaded", "invalid pending blob state")
      cache[id] = try Record(state: state, bytes: Array(bytes), storageId: field(value, "storageId")?.asString(), uploadTime: field(value, "uploadTime")?.asNumber(), ttl: field(value, "minTTLInSeconds")?.asNumber())
      pending.append(id)
      pendingOnly.append(id)
      try track(id, start: true)
    }
  }
  public func createBlob(_ bytes: [UInt8], payloadPending: Bool, completion: @escaping (BlobHandle) throws -> Void) throws {
    if attachState == .attaching {
      waitingForAttached.append { [self] in try createBlob(bytes, payloadPending: payloadPending, completion: completion) }
      return
    }
    try createBlob(bytes, localId: generateUUID(), payloadPending: payloadPending, completion: completion)
  }
  public func createBlob(_ bytes: [UInt8], localId id: JSString, payloadPending: Bool, completion: @escaping (BlobHandle) throws -> Void) throws {
    if attachState == .attaching {
      waitingForAttached.append { [self] in try createBlob(bytes, localId: id, payloadPending: payloadPending, completion: completion) }
      return
    }
    cache[id] = Record(state: "localOnly", bytes: bytes)
    if attachState == .detached {
      cache[id]?.state = "uploading"
      try upload(bytes) { [self] result in
        let response = try result.get()
        cache[id] = Record(state: "attached", bytes: bytes)
        redirects.set(id, response.id)
        try completion(BlobHandle(path: getGCNodePathFromLocalId(id), payloadPending: false, get: { [self] completion in try getBlob(id, completion: completion) }))
      }
    } else if payloadPending {
      let handle = BlobHandle(path: getGCNodePathFromLocalId(id), payloadPending: true, get: { completion in try completion(.success(bytes)) }, share: { [weak self] in
        guard let self else { throw JSONDecodingError("blob manager disposed") }
        try self.uploadAndAttach(id)
      }, attach: { [weak self] in
        guard let self else { throw JSONDecodingError("blob manager disposed") }
        if let record = self.cache[id], record.state != "attached", !self.pending.contains(id) { self.pending.append(id) }
      })
      handles[id] = handle
      try completion(handle)
    } else {
      legacyCompletions[id] = completion
      try uploadAndAttach(id)
    }
  }
  private func expired(_ record: Record) -> Bool {
    guard let ttl = record.ttl, let time = record.uploadTime else { return false }
    return now() - time > ttl / 2 * 1000
  }
  private func uploadAndAttach(_ id: JSString) throws {
    guard let record = cache[id] else { throw JSONDecodingError("0xc80") }
    try require(record.state == "localOnly" || record.state == "uploaded", "0xc80")
    try track(id, start: true)
    guard cache[id] != nil else { return }
    if record.state == "uploaded", !expired(record) {
      try attachUploaded(id)
      return
    }
    cache[id] = Record(state: "uploading", bytes: record.bytes)
    try upload(record.bytes) { [self] result in
      // A late completion must not resurrect a record authoritatively attached (or aborted).
      guard cache[id]?.state == "uploading" else { return }
      switch result {
      case .success(let response):
        cache[id] = Record(state: "uploaded", bytes: record.bytes, storageId: response.id, uploadTime: now(), ttl: response.minTTLInSeconds)
        try attachUploaded(id)
      case .failure(let error):
        cache[id] = nil
        pending.removeAll { $0 == id }
        try track(id, start: false)
        if let handle = handles[id] { try handle.notifyFailed(error) }
        else { throw error }
      }
    }
  }
  private func attachUploaded(_ id: JSString) throws {
    guard let record = cache[id], record.state == "uploaded", let storage = record.storageId else { throw JSONDecodingError("0xc82") }
    cache[id]?.state = "attaching"
    try sendBlobAttachMessage(object([("localId", .string(id)), ("blobId", .string(storage))]))
  }
  public func abort(_ id: JSString) throws {
    cache[id] = nil
    pending.removeAll { $0 == id }
    try track(id, start: false)
    if let handle = handles[id] { try handle.notifyFailed(JSONDecodingError("uploadBlob aborted")) }
  }
  public func reSubmit(_ metadata: JSONValue) throws {
    let (id, storage) = try decodeMetadata(metadata)
    guard let record = cache[id], record.state == "attaching" else { return }
    if expired(record) {
      cache[id] = Record(state: "localOnly", bytes: record.bytes)
      try uploadAndAttach(id)
    } else { try sendBlobAttachMessage(object([("localId", .string(id)), ("blobId", .string(storage))])) }
  }
  private func decodeMetadata(_ value: JSONValue) throws -> (JSString, JSString) {
    try (value.member("localId").asString(), value.member("blobId").asString())
  }
  public func processBlobAttachMessage(_ metadata: JSONValue) throws {
    let (id, storage) = try decodeMetadata(metadata)
    if let record = cache[id] {
      cache[id] = Record(state: "attached", bytes: record.bytes)
      pending.removeAll { $0 == id }
      pendingOnly.removeAll { $0 == id }
    }
    redirects.set(id, storage)
    redirects.set(storage, storage)
    try track(id, start: false)
    if let handle = handles.removeValue(forKey: id) { try handle.notifyShared() }
    if let completion = legacyCompletions.removeValue(forKey: id) {
      try completion(BlobHandle(path: getGCNodePathFromLocalId(id), payloadPending: false, get: { [self] completion in try getBlob(id, completion: completion) }))
    }
    let waiting = waitingReads.removeValue(forKey: id) ?? []
    for completion in waiting { try read(storage, completion) }
  }
  public func getBlob(_ id: JSString, payloadPending: Bool = false, completion: @escaping (Result<[UInt8], any Error>) throws -> Void) throws {
    let path = getGCNodePathFromLocalId(id)
    try require(!isBlobDeleted(path), "Blob was deleted")
    try blobRequested(path)
    if let record = cache[id] {
      try completion(.success(record.bytes))
      return
    }
    if let storage = redirects.get(id) {
      try read(storage, completion)
      return
    }
    try require(payloadPending, "0x11f")
    waitingReads[id, default: []].append(completion)
  }
  public func sharePendingBlobs() throws {
    let ids = pendingOnly
    pendingOnly.removeAll()
    for id in ids { try uploadAndAttach(id) }
  }
  public func getPendingBlobs() throws -> JSONValue? {
    var output = JSObject<JSONValue>()
    for id in pending {
      guard let record = cache[id] else { throw JSONDecodingError("0xc83") }
      try require(record.state != "attached", "0xc84")
      let blob = string(Data(record.bytes).base64EncodedString())
      if record.state == "localOnly" || record.state == "uploading" {
        output[id] = object([("state", string("localOnly")), ("blob", blob)])
      } else {
        output[id] = object([("state", string("uploaded")), ("blob", blob), ("storageId", record.storageId.map(JSONValue.string)), ("uploadTime", record.uploadTime.map(JSONValue.number)), ("minTTLInSeconds", record.ttl.map(JSONValue.number))])
      }
    }
    return output.isEmpty ? nil : .object(output)
  }
  public func patchRedirectTable(_ table: [(JSString, JSString)]) throws {
    try require(attachState == .detached, "0x252")
    let translations = Dictionary(table, uniquingKeysWith: { _, last in last })
    try require(Set(redirects.entries.map(\.value)).count == translations.count, "0x391")
    for (id, pseudo) in redirects.entries {
      guard let storage = translations[pseudo] else { throw JSONDecodingError("0xc53") }
      redirects.set(id, storage)
      redirects.set(storage, storage)
    }
  }
  public func deleteSweepReadyNodes(_ routes: [JSString]) throws -> [JSString] {
    var unused: Set<JSString> = []
    for route in routes {
      let parts = splitRuntimePath(route)
      try require(parts.count == 3 && parts[1] == "_blobs", "0x5bd")
      let id = parts[2]
      if let storage = redirects.get(id) {
        unused.insert(storage)
        redirects.delete(id)
      }
    }
    for (id, storage) in redirects.entries where id != storage { unused.remove(storage) }
    for storage in unused { redirects.delete(storage) }
    return routes
  }
  public func getGCData() -> JSONValue {
    var nodes = JSObject<JSONValue>()
    for (id, storage) in redirects.entries where id != storage { nodes[getGCNodePathFromLocalId(id)] = .array([]) }
    return object([("gcNodes", .object(nodes))])
  }
  public func summarize() -> JSONValue {
    summarizeBlobManagerState(redirects)
  }
}
