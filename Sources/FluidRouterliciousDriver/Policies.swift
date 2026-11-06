/// Ports policies.ts with documentServiceFactory.ts defaults.
/// Prefetch, concurrency limits and long-polling downgrade remain unimplemented.
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
