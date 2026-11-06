import Foundation
import FluidJS

/// Ports dataStoreRuntime.ts LegacyTypeAwareRegistry, including the upstream reverse-proxy URL rule.
public struct LegacyTypeAwareRegistry {
    private let base: [JSString: ChannelFactory]
    public init(_ base: [JSString: ChannelFactory]) { self.base = base }
    public func get(_ name: JSString) -> ChannelFactory? {
        if let factory = base[name] { return factory }
        let prefix = "https://graph.microsoft.com/types/"
        let text = name.description
        let alternate = text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : prefix + text
        if let factory = base[JSString(alternate)] { return factory }
        if URL(string: text)?.scheme != nil && text.contains("graph.microsoft") {
            let segment = text.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return base[JSString(segment)] ?? base[JSString(prefix + segment)]
        }
        return nil
    }
}
