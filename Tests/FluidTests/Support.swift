import FluidJS
import FluidSequence
import FluidTestRuntimeUtils
import Observation
import Testing

@testable import Fluid
import FluidMap

/// Two native SharedStrings over port channels that share one mock sequencer.
struct TwoStrings {
    let factory = MockContainerRuntimeFactory<FluidSequence.SharedString>()
    let a: Fluid.SharedString
    let b: Fluid.SharedString

    init() throws {
        let portA = FluidSequence.SharedString(id: "text")
        let portB = FluidSequence.SharedString(id: "text")
        _ = factory.createContainerRuntime(clientId: "A", channel: portA)
        _ = factory.createContainerRuntime(clientId: "B", channel: portB)
        a = try #require(Fluid.SharedString.kind.adopt(portA))
        b = try #require(Fluid.SharedString.kind.adopt(portB))
    }

    func sync() throws {
        try factory.processAllMessages()
    }
}

/// Two native SharedMaps over port channels that share one mock sequencer.
struct TwoMaps<Value: Codable> {
    let factory = MockContainerRuntimeFactory<FluidMap.SharedMap>()
    let a: Fluid.SharedMap<Value>
    let b: Fluid.SharedMap<Value>

    init() throws {
        let portA = FluidMap.SharedMap(id: "map")
        let portB = FluidMap.SharedMap(id: "map")
        _ = factory.createContainerRuntime(clientId: "A", channel: portA)
        _ = factory.createContainerRuntime(clientId: "B", channel: portB)
        a = try #require(Fluid.SharedMap<Value>.kind.adopt(portA))
        b = try #require(Fluid.SharedMap<Value>.kind.adopt(portB))
    }

    func sync() throws {
        try factory.processAllMessages()
    }
}

/// Counts how many times the values `read` touches announce a change, re-arming after each one,
/// as SwiftUI does for a view that keeps rendering. Changes are announced synchronously on the
/// owner, which is the main actor in these tests.
@MainActor
final class ChangeCounter {
    private(set) var count = 0
    private let read: () -> Void

    init(_ read: @escaping () -> Void) {
        self.read = read
        track()
    }

    private func track() {
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.count += 1
                self.track()
            }
        }
    }
}
