import FluidSharedObjectBase

/// One sequenced register value. Port of `packages/dds/register-collection/src/consensusRegisterCollection.ts`
/// ILocalRegister. The summary wraps `value` as `{type: "Plain", value}`, kept for backwards compatibility
/// with runtimes before 0.17. `value` here is the inner value, which may be JS undefined.
struct ILocalRegister {
  /// The sequence number when this write was sequenced.
  let sequenceNumber: Int
  let value: FluidValue
}

/// The state of one key. Port of `consensusRegisterCollection.ts` ILocalData.
struct ILocalData {
  /// The atomic winner: the first write to be sequenced with a refSeq that saw the previous atomic value.
  var atomic: ILocalRegister
  /// Every concurrent version still awaiting consensus, oldest first.
  var versions: [ILocalRegister]
}
