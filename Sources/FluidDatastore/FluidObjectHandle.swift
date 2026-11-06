import FluidJS
import FluidSharedObjectBase

/// Ports packages/runtime/datastore/src/fluidHandle.ts FluidObjectHandle.
public final class FluidObjectHandle<Value> {
    public let absolutePath: JSString
    private let value: () throws -> Value
    private weak var routeContext: FluidDataStoreRuntime?
    public init(value: @escaping () throws -> Value, path: JSString, routeContext: FluidDataStoreRuntime) {
        self.value = value
        self.routeContext = routeContext
        absolutePath = path.length == 0 ? routeContext.absolutePath : datastorePath(routeContext.absolutePath, path)
    }
    public var isAttached: Bool { routeContext?.attachState != .detached && routeContext != nil }
    public func get() throws -> Value { try value() }
    public func attachGraph() { routeContext?.makeVisibleAndAttachGraph() }
    public var handle: FluidHandle { FluidHandle(absolutePath: absolutePath) }
}
