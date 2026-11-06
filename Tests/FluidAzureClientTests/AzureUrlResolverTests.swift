import FluidDriverDefinitions
import FluidJS
import Testing

@testable import FluidAzureClient

/// Golden values from the TS 3.11.0 `AzureUrlResolver`, `createAzureCreateNewRequest` and the
/// request URL `AzureClient.getContainer` builds (`new URL(endpoint)` plus
/// `searchParams.append`), printed by node in harness/.
struct AzureUrlResolverTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let endpoint: String
        let tenantId: String
        let containerId: String
        let requestUrl: String
        let resolved: String
        let createNewUrl: String
        let createNewResolved: String
        var testDescription: String { endpoint }
    }

    static let cases = [
        Case(
            endpoint: "http://localhost:7081",
            tenantId: "local",
            containerId: "abc",
            requestUrl: "http://localhost:7081/?storage=http%253A%252F%252Flocalhost%253A7081&tenantId=local&containerId=abc",
            resolved: #"{"endpoints":{"deltaStorageUrl":"http://localhost:7081/deltas/local/abc","ordererUrl":"http://localhost:7081","storageUrl":"http://localhost:7081/repos/local"},"id":"abc","tokens":{},"type":"fluid","url":"http://localhost:7081/local/abc"}"#,
            createNewUrl: "http://localhost:7081/?storage=http%253A%252F%252Flocalhost%253A7081&tenantId=local",
            createNewResolved: #"{"endpoints":{"deltaStorageUrl":"http://localhost:7081/deltas/local/new","ordererUrl":"http://localhost:7081","storageUrl":"http://localhost:7081/repos/local"},"id":"","tokens":{},"type":"fluid","url":"http://localhost:7081/local/new"}"#),
        Case(
            endpoint: "https://us.fluidrelay.azure.com",
            tenantId: "tenant id+/x",
            containerId: "a b/c?d&é",
            requestUrl: "https://us.fluidrelay.azure.com/?storage=https%253A%252F%252Fus.fluidrelay.azure.com&tenantId=tenant%2520id%252B%252Fx&containerId=a%2520b%252Fc%253Fd%2526%25C3%25A9",
            resolved: #"{"endpoints":{"deltaStorageUrl":"https://us.fluidrelay.azure.com/deltas/tenant id+/x/a b/c?d&é","ordererUrl":"https://us.fluidrelay.azure.com","storageUrl":"https://us.fluidrelay.azure.com/repos/tenant id+/x"},"id":"a b/c?d&é","tokens":{},"type":"fluid","url":"https://us.fluidrelay.azure.com/tenant id+/x/a b/c?d&é"}"#,
            createNewUrl: "https://us.fluidrelay.azure.com/?storage=https%253A%252F%252Fus.fluidrelay.azure.com&tenantId=tenant%2520id%252B%252Fx",
            createNewResolved: #"{"endpoints":{"deltaStorageUrl":"https://us.fluidrelay.azure.com/deltas/tenant id+/x/new","ordererUrl":"https://us.fluidrelay.azure.com","storageUrl":"https://us.fluidrelay.azure.com/repos/tenant id+/x"},"id":"","tokens":{},"type":"fluid","url":"https://us.fluidrelay.azure.com/tenant id+/x/new"}"#),
        // An endpoint's own query is re-serialized form-encoded when the client appends to it.
        Case(
            endpoint: "http://localhost:7081/base?x=1%202",
            tenantId: "local",
            containerId: "id",
            requestUrl: "http://localhost:7081/base?x=1+2&storage=http%253A%252F%252Flocalhost%253A7081%252Fbase%253Fx%253D1%2525202&tenantId=local&containerId=id",
            resolved: #"{"endpoints":{"deltaStorageUrl":"http://localhost:7081/deltas/local/id","ordererUrl":"http://localhost:7081","storageUrl":"http://localhost:7081/base?x=1%202/repos/local"},"id":"id","tokens":{},"type":"fluid","url":"http://localhost:7081/local/id"}"#,
            createNewUrl: "http://localhost:7081/base?x=1+2&storage=http%253A%252F%252Flocalhost%253A7081%252Fbase%253Fx%253D1%2525202&tenantId=local",
            createNewResolved: #"{"endpoints":{"deltaStorageUrl":"http://localhost:7081/deltas/local/new","ordererUrl":"http://localhost:7081","storageUrl":"http://localhost:7081/base?x=1%202/repos/local"},"id":"","tokens":{},"type":"fluid","url":"http://localhost:7081/local/new"}"#),
    ]

    @Test(arguments: cases) func requestUrlMatchesTypeScript(_ golden: Case) throws {
        let url = try createAzureRequestUrl(endpoint: golden.endpoint, tenantId: golden.tenantId, containerId: golden.containerId)
        #expect(url == golden.requestUrl)
    }

    @Test(arguments: cases) func resolveMatchesTypeScript(_ golden: Case) async throws {
        let resolved = try #require(try await AzureUrlResolver().resolve(IRequest(url: golden.requestUrl)))
        #expect(JSON.stringify(resolved.json) == golden.resolved)
    }

    @Test(arguments: cases) func createNewRequestMatchesTypeScript(_ golden: Case) async throws {
        let request = try createAzureCreateNewRequest(endpointUrl: golden.endpoint, tenantId: golden.tenantId)
        #expect(request.url == golden.createNewUrl)
        #expect(request.headers.map { JSON.stringify(.object($0)) } == #"{"createNew":true}"#)
        let resolved = try #require(try await AzureUrlResolver().resolve(request))
        #expect(JSON.stringify(resolved.json) == golden.createNewResolved)
    }

    @Test func absoluteUrlAppendsTheRelativeUrl() async throws {
        let resolved = try #require(try await AzureUrlResolver().resolve(IRequest(url: Self.cases[0].requestUrl)))
        #expect(try await AzureUrlResolver().getAbsoluteUrl(resolved, relativeUrl: "rel/x") == "http://localhost:7081/local/abc/rel/x")
    }

    /// The TS error messages, in the order decodeAzureUrl and resolve check.
    @Test(arguments: [
        ("http://localhost:7081/?storage=x&tenantId=y", "Azure URL did not contain containerId"),
        ("http://localhost:7081/?tenantId=y", "Azure URL did not contain a storage URL"),
        ("http://localhost:7081/?storage=x", "Azure URL did not contain a tenant ID"),
        ("http://localhost:7081/?storage=%25E0%25A4%25A&tenantId=y&containerId=1", "URIError: URI malformed"),
    ])
    func rejectsIncompleteUrls(_ url: String, _ message: String) async throws {
        do {
            _ = try await AzureUrlResolver().resolve(IRequest(url: url))
            Issue.record("resolved \(url)")
        } catch {
            #expect(String(describing: error) == message)
        }
    }
}
