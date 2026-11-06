import FluidDriverDefinitions
import FluidJS
import FluidTestRuntimeUtils

// Quorum membership, as `harness/src/peer.ts` drives it: `createClient.members` seeds the quorum
// and `membership` reconciles it.

/// `createClient`: the quorum starts with `params.members`, or with the client alone.
func initialQuorum(_ params: JSONValue) throws -> MockQuorumClients {
  let quorum = MockQuorumClients()
  // The mock runtime joins the quorum itself, so an absent list leaves it empty.
  guard let members = try params.asObject()["members"] else {
    return quorum
  }
  for member in try members.asArray() {
    quorum.addMember(try member.asString(), .object(JSObject()))
  }
  return quorum
}

extension RuntimeClient {
  /// `membership`: removes every member not listed, then adds the listed ones that are missing, in
  /// order.
  func membership(_ members: [JSString]) {
    let quorum = runtime.quorum
    for id in quorum.getMembers().keys where !members.contains(id) {
      quorum.removeMember(id)
    }
    for id in members where quorum.getMember(id) == nil {
      quorum.addMember(id, .object(JSObject()))
    }
  }
}
