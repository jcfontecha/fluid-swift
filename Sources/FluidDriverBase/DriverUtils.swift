import FluidDriverDefinitions

/// Ports driver-base/src/driverUtils.ts `validateMessages`. A batch that is not one consecutive
/// run from `from` is cut: to nothing when strict or when it starts elsewhere, otherwise to its
/// first consecutive run.
public func validateMessages(_ reason: String, _ messages: inout [ISequencedDocumentMessage], from: Int, strict: Bool = true) {
    guard let first = messages.first, let last = messages.last else { return }
    guard last.sequenceNumber + 1 != from + messages.count else { return }
    if strict || from != first.sequenceNumber {
        messages.removeAll()
        return
    }
    var validOpsCount = 1
    while validOpsCount < messages.count,
        messages[validOpsCount].sequenceNumber == messages[validOpsCount - 1].sequenceNumber + 1
    {
        validOpsCount += 1
    }
    messages.removeLast(messages.count - validOpsCount)
}
