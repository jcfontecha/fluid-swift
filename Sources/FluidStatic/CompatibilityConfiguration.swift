import FluidJS

/// Ports fluid-static/src/compatibilityConfiguration.ts. TS ignores the version argument.
public func defaultRuntimeOptionsForMinVersion(_ minVersionForCollab: String) -> JSObject<JSONValue> {
    var options = JSObject<JSONValue>()
    options["enableRuntimeIdCompressor"] = .string("on")
    return options
}
