internal import FluidTinyliciousClient

/// Creates and loads containers on a Tinylicious service on this machine, with its insecure tokens.
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
        let (container, _) = try await portClient().getContainer(
            id, containerSchema: InitialObjects.schema(of: schema), oldestSupportedClient: "2.0.0", isolation: owner)
        return try FluidContainer(port: container)
    }

    /// A new, detached container whose objects are usable right away. `attach()` stores it and
    /// returns its id. The container and its objects belong to `owner`. Documents this client
    /// writes stay readable by Fluid Framework 2.0 clients and later.
    public func createContainer<Schema: ContainerSchema>(
        schema: Schema.Type, isolation owner: isolated any Actor
    ) async -> FluidContainer<Schema> {
        do {
            let (container, _) = try await portClient().createContainer(
                InitialObjects.schema(of: schema), oldestSupportedClient: "2.0.0", isolation: owner)
            return try FluidContainer(port: container)
        } catch {
            preconditionFailure("Creating a detached container failed: \(error)")
        }
    }

    private func portClient() throws -> FluidTinyliciousClient.TinyliciousClient {
        try FluidTinyliciousClient.TinyliciousClient(
            properties: TinyliciousClientProps(connection: TinyliciousConnectionConfig(port: port)))
    }
}
