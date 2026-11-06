internal import FluidTinyliciousClient

/// Loads containers from a Tinylicious service on this machine, with its insecure tokens.
public struct TinyliciousClient: Sendable {
    private let port: Int

    /// The service at `http://localhost:<port>`.
    public init(port: Int = 7070) {
        self.port = port
    }

    /// Loads the container `id`. The container and its objects belong to `owner`. Documents this
    /// client writes stay readable by Fluid Framework 2.0 clients and later.
    public func loadContainer<Schema: ContainerSchema>(
        _ id: String, schema: Schema.Type, isolation owner: isolated any Actor
    ) async throws -> FluidContainer<Schema> {
        let client = try FluidTinyliciousClient.TinyliciousClient(
            properties: TinyliciousClientProps(connection: TinyliciousConnectionConfig(port: port)))
        let (container, _) = try await client.getContainer(
            id, containerSchema: InitialObjects.schema(of: schema), oldestSupportedClient: "2.0.0", isolation: owner)
        return try FluidContainer(port: container)
    }
}
