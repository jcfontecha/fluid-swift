import FluidContainerDefinitions
import FluidDriverDefinitions
import FluidJS

public enum QuorumEvent {
    case addMember(JSString, ISequencedClient)
    case removeMember(JSString)
    case addProposal(ISequencedProposal)
    case approveProposal(ICommittedProposal)
}

public enum DeltaManagerEvent {
    case op(ISequencedDocumentMessage, duration: Double)
    case connect(IConnected, opsBehind: Int?)
    case disconnect(String, error: (any Error)?)
}
