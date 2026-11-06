import FluidJS

/// Ports blobManager/blobManager.ts path helpers without decoding UTF-16 into Swift String.
public func getGCNodePathFromLocalId(_ localId: JSString) -> JSString {
  var units = JSString("/_blobs/").utf16
  units.append(contentsOf: localId.utf16)
  return JSString(utf16: units)
}
public func isBlobPath(_ path: JSString) -> Bool {
  let parts = splitRuntimePath(path)
  return parts.count == 3 && parts[1] == "_blobs"
}
func splitRuntimePath(_ path: JSString) -> [JSString] {
  path.utf16.split(separator: 47, omittingEmptySubsequences: false).map { JSString(utf16: ContiguousArray($0)) }
}
