import FluidDatastoreDefinitions
import FluidJS
import Foundation

/// Ports presence-runtime/src/runtime/extension/containerPresence.ts: the container extension
/// that gives a container one presence instance.

/// `ExtensionCompatibilityDetails` (runtime-definitions).
public struct ExtensionCompatibilityDetails: Equatable, Sendable {
  public var generation: Int
  public var version: JSString
  public var capabilities: Set<JSString>

  public init(generation: Int, version: JSString, capabilities: Set<JSString>) {
    self.generation = generation
    self.version = version
    self.capabilities = capabilities
  }
}

/// `ContainerExtensionId` for presence. The extension address is `/ext/<id>/` (trailing slash).
public let presenceExtensionId: JSString = "dis:bb89f4c0-80fd-4f0c-8469-4f2848ee7f4a"

/// `pkgVersion` (presence-runtime/src/packageVersion.ts).
let presencePackageVersion: JSString = "3.11.0"

let presenceCompatibility = ExtensionCompatibilityDetails(
  generation: 1, version: presencePackageVersion, capabilities: [])

/// Minimal compatible package version. An existing presence extension registered with this
/// version or higher can be used instead of instantiating a new instance.
let minimalCompatiblePackageVersion: JSString = "2.71.0"

/// JS `Number.parseFloat` over the longest numeric prefix, enough for version fragments.
private func parseFloat(_ text: String) -> Double {
  var prefix = ""
  var seenDot = false
  for character in text {
    if character.isASCII && character.isNumber {
      prefix.append(character)
    } else if character == "." && !seenDot {
      seenDot = true
      prefix.append(character)
    } else {
      break
    }
  }
  return Double(prefix) ?? .nan
}

private func assertCompatibilityInvariants(_ compatibility: ExtensionCompatibilityDetails) throws {
  try assertPresence(compatibility.generation == presenceCompatibility.generation, "0xc97")
  let version = compatibility.version.description
  try assertPresence(version.hasPrefix("2."), "0xc98")
  try assertPresence(
    parseFloat(String(version.dropFirst(2)))
      < parseFloat(String(presenceCompatibility.version.description.dropFirst(2))),
    "0xc99")
  try assertPresence(presenceCompatibility.capabilities.isEmpty, "0xc9a")
}

/// Adapts an `ExtensionHost` to `IEphemeralRuntime`: signals leave through
/// `host.submitAddressedSignal([], message)`.
private final class HostBackedEphemeralRuntime: IEphemeralRuntime {
  private let host: any ExtensionHost

  init(host: any ExtensionHost) {
    self.host = host
  }

  var clock: any PresenceClock { host.clock }
  var supportedFeatures: Set<JSString> { host.supportedFeatures }
  func getJoinedStatus() -> JoinedStatus { host.getJoinedStatus() }
  func getClientId() -> ClientConnectionId? { host.getClientId() }
  func getQuorum() -> any IQuorumClients { host.getQuorum() }
  func getAudience() -> any IAudience { host.getAudience() }

  func onDisconnected(_ listener: @escaping () throws -> Void) {
    host.onDisconnected(listener)
  }

  func submitSignal(_ message: OutboundPresenceMessage) throws {
    try host.submitAddressedSignal([], message: message.json)
  }
}

/// Ports `ContainerPresenceManager`: the common presence manager for a container.
public final class ContainerPresenceManager {
  public let compatibility = presenceCompatibility
  public let interface: PresenceManager

  /// The attendee ID is a new session ID, distinct from the service user ID and connection ID.
  public init(host: any ExtensionHost, attendeeId: AttendeeId = createSessionId()) throws {
    interface = try createPresenceManager(
      runtime: HostBackedEphemeralRuntime(host: host), attendeeId: attendeeId)
  }

  /// There have not yet been any changes that would require action to upgrade, and mixed runtime
  /// versions are not yet expected.
  public func handleVersionOrCapabilitiesMismatch(
    ourExistingInstantiation: ExtensionCompatibilityDetails,
    newCompatibilityRequest: ExtensionCompatibilityDetails
  ) throws -> Never {
    try assertPresence(ourExistingInstantiation == presenceCompatibility, "0xc9b")
    try assertCompatibilityInvariants(newCompatibilityRequest)
    throw PresenceError.assertionFailed("0xcb1")
  }

  public func onNewUse() {}

  public func processSignal(
    addressChain: [JSString], message: InboundExtensionMessage, local: Bool
  ) throws {
    try interface.processSignal(addressChain: addressChain, message: message, local: local)
  }
}

/// `createSessionId()` (id-compressor): a random version 4 UUID in lowercase.
public func createSessionId() -> AttendeeId {
  JSString(UUID().uuidString.lowercased())
}

/// Ports `ContainerPresenceFactory`.
public enum ContainerPresenceFactory {
  /// `hostRequirements`: minimum host generation 1, no required features.
  public static let hostMinSupportedGeneration = 1

  /// `instanceExpectations`: the presence compatibility with the minimal compatible version.
  public static let instanceExpectations = ExtensionCompatibilityDetails(
    generation: presenceCompatibility.generation, version: minimalCompatiblePackageVersion,
    capabilities: presenceCompatibility.capabilities)

  /// There have not yet been any changes that would require action to upgrade.
  public static func resolvePriorInstantiation(
    existingInstantiation: ExtensionCompatibilityDetails
  ) throws -> Never {
    try assertCompatibilityInvariants(existingInstantiation)
    throw PresenceError.assertionFailed("0xcb2")
  }

  public static func instantiateExtension(host: any ExtensionHost) throws -> ContainerPresenceManager {
    try ContainerPresenceManager(host: host)
  }
}
