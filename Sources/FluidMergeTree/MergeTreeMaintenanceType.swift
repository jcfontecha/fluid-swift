/// Ports mergeTreeDeltaCallback.ts MergeTreeMaintenanceType.
public enum MergeTreeMaintenanceType: Int {
  case append = -1
  case split = -2
  case unlink = -3
  case acknowledged = -4
}
