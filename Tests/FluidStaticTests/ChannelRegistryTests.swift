import Foundation
import Testing
import FluidJS
import FluidDatastore
import FluidMap
import FluidCounter
import FluidCell
import FluidRegisterCollection
import FluidSharedSummaryBlock
import FluidPactMap
import FluidTaskManager
import FluidOrderedCollection
import FluidLegacyDDS
import FluidSequence
import FluidMatrix
@testable import FluidStatic

/// Golden attributes come from `npm run fixtures:registry` (harness/src/registry/fixtures.ts),
/// which reads each 3.11.0 SharedObjectKind's `getFactory()`.
struct ChannelRegistryTests {
    private static let kinds: [(name: String, kind: any SharedObjectKind.Type)] = [
        ("SharedMap", SharedMap.self),
        ("SharedDirectory", SharedDirectory.self),
        ("SharedCounter", SharedCounter.self),
        ("SharedCell", SharedCell.self),
        ("ConsensusRegisterCollection", ConsensusRegisterCollection.self),
        ("SharedSummaryBlock", SharedSummaryBlockClass.self),
        ("PactMap", PactMapClass.self),
        ("TaskManager", TaskManagerClass.self),
        ("ConsensusQueue", ConsensusQueue.self),
        ("SharedArray", SharedArrayClass.self),
        ("SharedSignal", SharedSignalClass.self),
        ("SharedString", SharedString.self),
        ("SharedMatrix", SharedMatrix.self),
    ]

    private func golden() throws -> [JSONValue] {
        let url = try #require(Bundle.module.url(forResource: "channel-factories", withExtension: "json", subdirectory: "Fixtures"))
        return try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    }

    private func type(_ factory: ChannelFactory) throws -> JSString {
        try factory.attributes.member("type").asString()
    }

    @Test func everyFactoryMatchesTypeScriptAttributesByteForByte() throws {
        let golden = try golden()
        #expect(golden.count == Self.kinds.count)
        for (entry, expected) in zip(Self.kinds, golden) {
            #expect(try expected.member("name").asString() == JSString(entry.name))
            let factory = entry.kind.getFactory()
            #expect(try type(factory) == expected.member("type").asString())
            #expect(JSString(JSON.stringify(factory.attributes)) == (try expected.member("attributes").asString()))
        }
    }

    /// utils.spec.ts "should be able to handle basic DDS types".
    @Test func parsesBasicDDSTypes() throws {
        let schema = ContainerSchema(initialObjects: ["map": SharedMap.self, "text": SharedString.self])
        let sharedObjects = try parseDataObjectsFromSharedObjects(schema)
        #expect(try sharedObjects.map(type) == ["https://graph.microsoft.com/types/map", "https://graph.microsoft.com/types/mergeTree"])
    }

    /// utils.spec.ts "should be able to handle dup DDS types".
    @Test func deduplicatesKindsByIdentity() throws {
        let schema = ContainerSchema(
            initialObjects: ["map": SharedMap.self, "text": SharedString.self, "text2": SharedString.self])
        let sharedObjects = try parseDataObjectsFromSharedObjects(schema)
        #expect(try sharedObjects.map(type) == ["https://graph.microsoft.com/types/map", "https://graph.microsoft.com/types/mergeTree"])
    }

    /// utils.ts: initial objects in JS property order, then dynamic types.
    @Test func ordersInitialObjectsByJSPropertyOrderThenDynamicTypes() throws {
        let schema = ContainerSchema(
            initialObjects: ["text": SharedString.self, "1": SharedCounter.self],
            dynamicObjectTypes: [SharedMatrix.self, SharedString.self])
        let sharedObjects = try parseDataObjectsFromSharedObjects(schema)
        #expect(try sharedObjects.map(type) == [
            "https://graph.microsoft.com/types/counter",
            "https://graph.microsoft.com/types/mergeTree",
            "https://graph.microsoft.com/types/sharedmatrix",
        ])
    }

    @Test func rejectsSchemaWithoutDataTypes() throws {
        let schema = ContainerSchema(initialObjects: [:])
        #expect(throws: (any Error).self) { try parseDataObjectsFromSharedObjects(schema) }
        do {
            _ = try parseDataObjectsFromSharedObjects(schema)
        } catch {
            #expect(String(describing: error) == "Container cannot be initialized without any DataTypes")
        }
    }

    /// dataObjectFactory.ts appends SharedDirectory then SharedMap when the schema lacks them.
    @Test func rootDataObjectFactoryAppendsDirectoryAndMapDefaults() throws {
        let factory = try createDOProviderContainerRuntimeFactory(
            schema: ContainerSchema(initialObjects: ["text": SharedString.self]), oldestSupportedClient: "2.0.0")
        #expect(try factory.rootDataObjectFactory.sharedObjects.map(type) == [
            "https://graph.microsoft.com/types/mergeTree",
            "https://graph.microsoft.com/types/directory",
            "https://graph.microsoft.com/types/map",
        ])
    }

    @Test func rootDataObjectFactoryKeepsSchemaDirectoryAndMapPositions() throws {
        let factory = try createDOProviderContainerRuntimeFactory(
            schema: ContainerSchema(initialObjects: ["map": SharedMap.self, "dir": SharedDirectory.self]),
            oldestSupportedClient: "2.0.0")
        #expect(try factory.rootDataObjectFactory.sharedObjects.map(type) == [
            "https://graph.microsoft.com/types/map",
            "https://graph.microsoft.com/types/directory",
        ])
        #expect(factory.rootDataObjectFactory.type == "rootDO")
    }

    /// compatibilityConfiguration.spec.ts.
    @Test func defaultRuntimeOptionsEnableIdCompressor() {
        let options = defaultRuntimeOptionsForMinVersion("2.0.0")
        #expect(JSON.stringify(.object(options)) == #"{"enableRuntimeIdCompressor":"on"}"#)
    }
}
