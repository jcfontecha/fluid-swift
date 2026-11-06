internal import FluidDatastoreDefinitions
internal import FluidJS
internal import FluidMap
import Observation

/// A collaborative dictionary from `String` keys to `Value`s, last writer wins per key. Reads go
/// straight to the DDS and decode on every read; nothing is cached.
///
/// A stored value that does not decode as `Value`, for example one written by a TS client or an
/// older app version, reads as absent (and asserts in debug builds). A value that cannot be
/// encoded as JSON, such as a non-finite number or an integer beyond 2^53, traps. A key a TS
/// client wrote with a lone surrogate is listed with U+FFFD in its place, and reading it back by
/// that listed key finds nothing.
public final class SharedMap<Value: Codable>: Observable, SharedObject {
    public static var kind: SharedObjectKind<SharedMap<Value>> {
        SharedObjectKind(
            channelType: FluidMap.SharedMap.self,
            make: { id in SharedMap(port: FluidMap.SharedMap(id: id)) },
            adopt: { channel in (channel as? FluidMap.SharedMap).map(SharedMap.init(port:)) })
    }

    private let port: FluidMap.SharedMap
    private let registrar = ObservationRegistrar()
    private var listener = 0

    private init(port: FluidMap.SharedMap) {
        self.port = port
        listener = port.valueChanged.on { [weak self] changed, _ in
            self?.receive(changed)
        }
    }

    deinit {
        port.valueChanged.off(listener)
    }

    /// The value for `key`, or nil when it is absent. Setting nil deletes the key.
    public subscript(key: String) -> Value? {
        get {
            registrar.access(self, keyPath: \.[key])
            guard let json = port.get(JSString(key)) else {
                return nil
            }
            do {
                return try JSONValueCoding.decode(Value.self, from: json)
            } catch {
                assertionFailure("SharedMap value for \"\(key)\" does not decode as \(Value.self): \(error)")
                return nil
            }
        }
        set {
            do {
                if let newValue {
                    try port.set(JSString(key), encode(newValue))
                } else {
                    try port.delete(JSString(key))
                }
            } catch {
                dropIfClosed(error)
            }
        }
    }

    /// Every key, in insertion order.
    public var keys: [String] {
        registrar.access(self, keyPath: \.keys)
        return port.keys().map(\.description)
    }

    public func removeAll() {
        do {
            try port.clear()
        } catch {
            dropIfClosed(error)
        }
    }

    private func encode(_ value: Value) -> JSONValue {
        do {
            return try JSONValueCoding.encode(value)
        } catch {
            preconditionFailure("SharedMap value \(value) cannot be stored: \(error)")
        }
    }

    /// One key changed. The key set changed too when the key was added (no previous value) or
    /// deleted (no longer present). A clear emits this once per deleted key.
    private func receive(_ changed: IValueChanged) {
        let key = changed.key.description
        let keysChanged = changed.previousValue == nil || !port.has(changed.key)
        registrar.willSet(self, keyPath: \.[key])
        if keysChanged {
            registrar.willSet(self, keyPath: \.keys)
            registrar.didSet(self, keyPath: \.keys)
        }
        registrar.didSet(self, keyPath: \.[key])
    }

    /// Edits throw only when the DDS is closed or when an internal invariant breaks.
    private func dropIfClosed(_ error: any Error) {
        guard port.closed != nil else {
            preconditionFailure("SharedMap edit failed: \(error)")
        }
    }
}
