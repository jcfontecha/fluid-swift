import Foundation
import Testing
import FluidJS
import FluidStatic
import FluidContainerDefinitions
import FluidContainerLoader
@testable import FluidContainerRuntime
import FluidDriverDefinitions
import FluidMap
import FluidSequence
import FluidIdCompressor

private struct SummaryCaptured: Error {}

private actor AttachCapture: IDocumentServiceFactory {
    var summary: SummaryTree?
    func createDocumentService(_ resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws -> any IDocumentService {
        throw SummaryCaptured()
    }
    func createContainer(_ summary: SummaryTree?, resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws -> any IDocumentService {
        self.summary = summary
        throw SummaryCaptured()
    }
}

private struct CreateResolver: IUrlResolver {
    func resolve(_ request: IRequest) async throws -> IResolvedUrl? {
        try IResolvedUrl(json: JSON.parse(#"{"type":"fluid","id":"new","url":"http://localhost/tenant/new","tokens":{},"endpoints":{}}"#))
    }
    func getAbsoluteUrl(_ resolvedUrl: IResolvedUrl, relativeUrl: String) async throws -> String {
        resolvedUrl.url.description
    }
}

private struct TwinFactory: IRuntimeFactory {
    let metadataInputs: JSONValue
    let sessionId: String
    let allocations: Int
    func instantiateRuntime(_ context: IContainerContext, existing: Bool) throws -> (runtime: ContainerRuntime, entryPoint: AnyObject) {
        let factory = try createDOProviderContainerRuntimeFactory(
            schema: ContainerSchema(initialObjects: ["text": SharedString.self, "map": SharedMap.self]),
            oldestSupportedClient: "2.0.0")
        let result = try factory.instantiateRuntime(context, existing: existing)
        // Inputs shared by twins, before edits. No summary normalization is permitted.
        var metadata = try #require(result.runtime.metadata).asObject()
        metadata["createContainerTimestamp"] = try metadataInputs.member("createContainerTimestamp")
        metadata["telemetryDocumentId"] = try metadataInputs.member("telemetryDocumentId")
        result.runtime.metadata = .object(metadata)
        result.runtime.idCompressor = try IdCompressor(sessionId, writeVersion: 2)
        for _ in 0..<allocations {
            _ = try result.runtime.idCompressor.generateCompressedId()
        }
        return result
    }
}

struct DetachedCreationTests {
    @MainActor @Test func attachSummaryMatchesOracle() async throws {
        let url = Bundle.module.url(forResource: "create", withExtension: "json", subdirectory: "Fixtures")!
        let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
        for fixture in fixtures {
            let expected = try fixture.member("summary")
            let metadata = try JSON.parse(expected.member("tree").member(".app").member("tree").member(".metadata").member("content").asString().description)
            let capture = AttachCapture()
            let container = try await createDetachedContainer(ICreateDetachedContainerProps(
                urlResolver: CreateResolver(), documentServiceFactory: capture,
                runtimeFactory: TwinFactory(metadataInputs: metadata, sessionId: fixture.member("sessionId").asString().description, allocations: fixture.member("seed").asInt()),
                codeDetails: JSON.parse(#"{"package":"no-dynamic-package","config":{}}"#)), isolation: MainActor.shared)
            defer { container.dispose(nil) }
            #expect(container.attachState == .detached)
            #expect(container.isDirty)
            let fluid = try await createFluidContainer(container: container)
            let text = try #require(fluid.initialObjects["text"] as? SharedString)
            let map = try #require(fluid.initialObjects["map"] as? SharedMap)
            for edit in try fixture.member("edits").asArray() {
                try text.insertText(0, edit.member("text").asString())
                try map.set(edit.member("key").asString(), edit.member("value"))
            }
            if ProcessInfo.processInfo.environment["L8_PLANT_DIVERGENCE"] == "1" {
                try map.set("planted", .bool(true))
            }
            do {
                try await container.attach(IRequest(url: "new"))
                Issue.record("capture must stop at the service boundary")
            } catch is SummaryCaptured {}
            let actual = try #require(await capture.summary)
            let seed = try fixture.member("seed").asInt()
            #expect(JSON.stringify(actual.json) == JSON.stringify(expected), "seed \(seed)")
        }
    }
}
