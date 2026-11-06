import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

/// Ports `MockAudience` (test-runtime-utils): `addMember` and `removeMember` always emit, even
/// when the membership does not change, and `getMembers()` returns a copy.
public final class MockAudience: IAudience {
  private var audienceMembers = JSMap<JSString, IClient>()
  private var nextToken = 0
  private var addListeners: [(Int, (JSString, IClient) throws -> Void)] = []
  private var removeListeners: [(Int, (JSString) throws -> Void)] = []

  public init() {}

  public func addMember(_ clientId: JSString, _ member: IClient) throws {
    audienceMembers.set(clientId, member)
    for (_, listener) in addListeners {
      try listener(clientId, member)
    }
  }

  @discardableResult
  public func removeMember(_ clientId: JSString) throws -> Bool {
    let deleteResult = audienceMembers.delete(clientId)
    for (_, listener) in removeListeners {
      try listener(clientId)
    }
    return deleteResult
  }

  public func getMembers() -> JSMap<JSString, IClient> {
    audienceMembers
  }

  public func getMember(_ clientId: JSString) -> IClient? {
    audienceMembers.get(clientId)
  }

  public func onAddMember(_ listener: @escaping (JSString, IClient) throws -> Void) -> Int {
    nextToken += 1
    addListeners.append((nextToken, listener))
    return nextToken
  }

  public func onRemoveMember(_ listener: @escaping (JSString) throws -> Void) -> Int {
    nextToken += 1
    removeListeners.append((nextToken, listener))
    return nextToken
  }

  public func off(_ token: Int) {
    addListeners.removeAll { $0.0 == token }
    removeListeners.removeAll { $0.0 == token }
  }
}

/// Ports `MockQuorumClients` (test-runtime-utils). Members are the `{client, sequenceNumber}`
/// objects presence reads.
public final class MockQuorumClients: IQuorumClients {
  private var members = JSMap<JSString, JSONValue>()
  private var nextToken = 0
  private var addListeners: [(Int, (JSString, JSONValue) -> Void)] = []
  private var removeListeners: [(Int, (JSString) -> Void)] = []

  public init() {}

  public func addMember(_ id: JSString, _ client: JSONValue) {
    members.set(id, client)
    for (_, listener) in addListeners {
      listener(id, client)
    }
  }

  public func removeMember(_ id: JSString) {
    if members.delete(id) {
      for (_, listener) in removeListeners {
        listener(id)
      }
    }
  }

  public func getMembers() -> JSMap<JSString, JSONValue> {
    members
  }

  public func getMember(_ clientId: JSString) -> JSONValue? {
    members.get(clientId)
  }

  public func onAddMember(_ listener: @escaping (JSString, JSONValue) -> Void) -> Int {
    nextToken += 1
    addListeners.append((nextToken, listener))
    return nextToken
  }

  public func onRemoveMember(_ listener: @escaping (JSString) -> Void) -> Int {
    nextToken += 1
    removeListeners.append((nextToken, listener))
    return nextToken
  }

  public func off(_ token: Int) {
    addListeners.removeAll { $0.0 == token }
    removeListeners.removeAll { $0.0 == token }
  }
}

/// An `IClient` as the service describes a connection: `mode`, interactive capability and a user.
public func mockClient(write: Bool, interactive: Bool, name: JSString) throws -> IClient {
  var capabilities = JSObject<JSONValue>()
  capabilities["interactive"] = .bool(interactive)
  var details = JSObject<JSONValue>()
  details["capabilities"] = .object(capabilities)
  var user = JSObject<JSONValue>()
  user["id"] = .string(name)
  var client = JSObject<JSONValue>()
  client["mode"] = .string(write ? "write" : "read")
  client["details"] = .object(details)
  client["permission"] = .array([])
  client["user"] = .object(user)
  client["scopes"] = .array([])
  return try IClient(json: .object(client))
}

/// A quorum member `{client, sequenceNumber}`.
public func mockQuorumMember(client: IClient, sequenceNumber: Int) -> JSONValue {
  var member = JSObject<JSONValue>()
  member["client"] = client.json
  member["sequenceNumber"] = .number(Double(sequenceNumber))
  return .object(member)
}

/// A signal that did not match `signalsExpected`.
public struct UnexpectedSignal: Error, CustomStringConvertible {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

/// Ports `MockEphemeralRuntime` (presence-runtime/src/test/mockEphemeralRuntime.ts): a runtime
/// whose audience and quorum hold eight clients (`client0`, `client1`, `localClient`, `client3` to
/// `client7`, the first six writers), and whose `submitSignal` checks each signal against
/// `signalsExpected`, in order.
public final class MockEphemeralRuntime: IEphemeralRuntime {
  public static let initialLocalClientConnectionId: ClientConnectionId = "localClient"

  public var clientId: ClientConnectionId?
  public var joined = false
  public let quorum = MockQuorumClients()
  public let audience = MockAudience()
  public let clock: any PresenceClock
  public var signalsExpected: [JSONValue]
  /// Tests that do not care about submitted signals set `runtime.submitSignal = () => {}` in TS.
  public var ignoresSignals = false
  public var supportedFeatures: Set<JSString> = ["submit_signals_v2"]
  private var disconnectedListeners: [() throws -> Void] = []

  public init(clock: any PresenceClock, signalsExpected: [JSONValue] = []) throws {
    self.clock = clock
    self.signalsExpected = signalsExpected

    let numWriteClients = 6
    let clientIds: [JSString] = [
      "client0", "client1", Self.initialLocalClientConnectionId, "client3", "client4", "client5",
      "client6", "client7",
    ]
    for (index, id) in clientIds.enumerated() {
      let letter = String(UnicodeScalar(UInt8(index + 65)))
      let write = index < numWriteClients
      let name = JSString(String(repeating: letter, count: 10))
      let client = try mockClient(write: write, interactive: true, name: name)
      try audience.addMember(id, client)
      if write {
        quorum.addMember(id, mockQuorumMember(client: client, sequenceNumber: 10 * index))
      }
    }
  }

  /// Removes a member from both audience and quorum.
  public func removeMember(_ clientId: ClientConnectionId) throws {
    guard let client = audience.getMember(clientId) else {
      throw UnexpectedSignal(description: "Attempting to remove unknown connection: \(clientId)")
    }
    if client.mode == .write {
      quorum.removeMember(clientId)
    }
    try audience.removeMember(clientId)
  }

  /// During connect the audience is refreshed: members are cleared, restored (except the old
  /// connection), then the new connection is added.
  public func connect(_ newClientId: ClientConnectionId, oldClientId: ClientConnectionId?) throws {
    let members = audience.getMembers()
    clientId = newClientId
    joined = true

    // Simulate the expected "clear".
    for (memberClientId, _) in members.entries {
      try audience.removeMember(memberClientId)
    }
    // Restore members.
    for (memberClientId, client) in members.entries where memberClientId != oldClientId {
      try audience.addMember(memberClientId, client)
    }
    // Finally add the new connection to the audience.
    try audience.addMember(newClientId, mockClient(write: true, interactive: true, name: "AAAAAAAAAA"))
  }

  public func disconnect() throws {
    joined = false
    for listener in disconnectedListeners {
      try listener()
    }
  }

  public func assertAllSignalsSubmitted() throws {
    if !signalsExpected.isEmpty {
      throw UnexpectedSignal(
        description: "Missing signals \(signalsExpected.map { JSON.stringify($0) })")
    }
  }

  public func getJoinedStatus() -> JoinedStatus {
    joined ? .joinedForReading : .disconnected
  }

  public func getClientId() -> ClientConnectionId? {
    clientId
  }

  public func getQuorum() -> any IQuorumClients {
    quorum
  }

  public func getAudience() -> any IAudience {
    audience
  }

  public func onDisconnected(_ listener: @escaping () throws -> Void) {
    disconnectedListeners.append(listener)
  }

  public func submitSignal(_ message: OutboundPresenceMessage) throws {
    if ignoresSignals {
      return
    }
    guard !signalsExpected.isEmpty else {
      throw UnexpectedSignal(description: "Unexpected signal: \(JSON.stringify(message.json))")
    }
    let expected = signalsExpected.removeFirst()
    // The signal is compared as it crosses the wire: non-finite numbers become `null`.
    let sent = try JSON.parse(JSON.stringify(message.json))
    guard sent == expected else {
      throw UnexpectedSignal(
        description: "Unexpected signal: \(JSON.stringify(sent)), expected \(JSON.stringify(expected))")
    }
  }
}
