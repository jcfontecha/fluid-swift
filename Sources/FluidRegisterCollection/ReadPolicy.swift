/// Read policies used when reading a register.
/// Port of `packages/dds/register-collection/src/interfaces.ts` ReadPolicy.
public enum ReadPolicy: Int, Sendable {
  /// On a concurrent update, returns the first agreed upon value amongst all clients.
  case atomic = 0
  /// Last writer wins: returns the last sequenced write.
  case lww = 1
}
