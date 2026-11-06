/// Ports policies.ts IRouterliciousDriverPolicies, with documentServiceFactory.ts's defaults.
/// The Swift driver reads `enableInternalSummaryCaching` (the snapshot-tree cache). Discovery and
/// whole-summary storage are not ported, so the factory rejects a policy that turns them on;
/// prefetch, request limits and long-polling downgrade are not ported and have no effect.
public struct IRouterliciousDriverPolicies: Sendable {
    public var enablePrefetch: Bool
    public var maxConcurrentStorageRequests: Int
    public var maxConcurrentOrdererRequests: Int
    public var enableDiscovery: Bool
    public var enableWholeSummaryUpload: Bool
    public var enableRestLess: Bool
    public var enableInternalSummaryCaching: Bool
    public var enableLongPollingDowngrade: Bool

    public init(
        enablePrefetch: Bool = true,
        maxConcurrentStorageRequests: Int = 100,
        maxConcurrentOrdererRequests: Int = 100,
        enableDiscovery: Bool = false,
        enableWholeSummaryUpload: Bool = false,
        enableRestLess: Bool = true,
        enableInternalSummaryCaching: Bool = true,
        enableLongPollingDowngrade: Bool = true
    ) {
        self.enablePrefetch = enablePrefetch
        self.maxConcurrentStorageRequests = maxConcurrentStorageRequests
        self.maxConcurrentOrdererRequests = maxConcurrentOrdererRequests
        self.enableDiscovery = enableDiscovery
        self.enableWholeSummaryUpload = enableWholeSummaryUpload
        self.enableRestLess = enableRestLess
        self.enableInternalSummaryCaching = enableInternalSummaryCaching
        self.enableLongPollingDowngrade = enableLongPollingDowngrade
    }
}
