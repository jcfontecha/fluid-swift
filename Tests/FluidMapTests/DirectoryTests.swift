import FluidJS
import FluidMap
import Testing

/// Detached delete disposes the child; a re-create is a fresh, empty instance. A large `__proto__`
/// value is an own property of its sparse blob, so it survives a load.
@Test func directoryRecreateAndSplit() throws {
  let directory = SharedDirectory(id: "dir")
  try directory.createSubDirectory("one").set("a", .number(1))
  try directory.deleteSubDirectory("one")
  let recreated = try directory.createSubDirectory("one")
  #expect(try recreated.entries().isEmpty)
  try recreated.set("__proto__", .string(JSString(String(repeating: "x", count: 8200))))
  let loaded = try SharedDirectory.load(id: "loaded", summary: directory.summarize())
  #expect(try loaded.getWorkingDirectory("/one")?.entries().count == 1)
}
