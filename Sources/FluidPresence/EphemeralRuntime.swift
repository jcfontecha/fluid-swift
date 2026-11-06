import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

/// Ports container-definitions `IAudience`, the part presence reads: a membership map with
/// `addMember` / `removeMember` events. `getMembers()` returns a copy.
///
/// Listeners may throw (a TS exception propagates through the emitter to whoever raised the
/// event), so the raising calls of an implementation throw too.
public protocol IAudience: AnyObject {
  func getMembers() -> JSMap<JSString, IClient>
  func getMember(_ clientId: JSString) -> IClient?

  @discardableResult
  func onAddMember(_ listener: @escaping (_ clientId: JSString, _ client: IClient) throws -> Void) -> Int

  @discardableResult
  func onRemoveMember(_ listener: @escaping (_ clientId: JSString) throws -> Void) -> Int

  func off(_ token: Int)
}

/// `JoinedStatus` (container-runtime-definitions).
public enum JoinedStatus {
  case disconnected
  case joinedForReading
  case joinedForWriting
}

/// Ports presence-runtime/src/runtime/runtimeTypes.ts `IEphemeralRuntime`: the subset of the
/// container extension host that presence needs, with `submitSignal` in place of
/// `submitAddressedSignal`. `clock` stands for the JS globals (see `PresenceClock`).
public protocol IEphemeralRuntime: AnyObject {
  var clock: any PresenceClock { get }
  var supportedFeatures: Set<JSString> { get }
  func getJoinedStatus() -> JoinedStatus
  func getClientId() -> ClientConnectionId?
  func getQuorum() -> any IQuorumClients
  func getAudience() -> any IAudience

  /// `events.on("disconnected", listener)`.
  func onDisconnected(_ listener: @escaping () throws -> Void)

  /// Submits the signal to be sent to other clients.
  func submitSignal(_ message: OutboundPresenceMessage) throws
}

/// Ports container-runtime-definitions `ExtensionHost` specialised to presence's
/// `ExtensionRuntimeProperties`: the same as `IEphemeralRuntime` but signals leave through
/// `submitAddressedSignal(addressChain, message)`, with `message` in its wire form
/// `{type, content, targetClientId?}`.
public protocol ExtensionHost: AnyObject {
  var clock: any PresenceClock { get }
  var supportedFeatures: Set<JSString> { get }
  func getJoinedStatus() -> JoinedStatus
  func getClientId() -> ClientConnectionId?
  func getQuorum() -> any IQuorumClients
  func getAudience() -> any IAudience
  func onDisconnected(_ listener: @escaping () throws -> Void)
  func submitAddressedSignal(_ addressChain: [JSString], message: JSONValue) throws
}

/// Ports container-runtime-definitions `InboundExtensionMessage`: what the container runtime hands
/// to an extension. `clientId` is `nil` (TS `null`) for signals from the service.
public struct InboundExtensionMessage {
  public var type: JSString
  public var content: JSONValue?
  public var clientId: ClientConnectionId?
  public var targetClientId: ClientConnectionId?

  public init(
    type: JSString, content: JSONValue?, clientId: ClientConnectionId?,
    targetClientId: ClientConnectionId? = nil
  ) {
    self.type = type
    self.content = content
    self.clientId = clientId
    self.targetClientId = targetClientId
  }

  /// The envelope `ContainerRuntime.processSignal` builds: `{clientId, content, type, targetClientId?}`.
  public init(json: JSONValue) throws {
    let object = try json.asObject()
    type = try requiredMember(object, "type").asString()
    content = object["content"]
    switch object["clientId"] {
    case .some(.string(let id)): clientId = id
    case .some(.null), .none: clientId = nil
    default: throw JSONDecodingError("expected string clientId")
    }
    switch object["targetClientId"] {
    case .some(.string(let id)): targetClientId = id
    default: targetClientId = nil
    }
  }
}
