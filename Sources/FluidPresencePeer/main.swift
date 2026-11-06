import FluidJS
import Foundation

// Differential peer for `npm run fuzz:presence` (harness/PROTOCOL.md, "Presence (H9)"): reads one
// scenario per line on stdin, runs it against FluidPresence and writes the trace on one line.
setvbuf(stdout, nil, _IOLBF, 0)
while let line = readLine() {
  do {
    let scenario = try JSON.parse(line)
    let trace = try Simulation(scenario: scenario).run()
    print(JSON.stringify(trace))
  } catch {
    FileHandle.standardError.write(Data("peer failure: \(error)\n".utf8))
    exit(1)
  }
}
