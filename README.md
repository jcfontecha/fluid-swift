# FluidSwift

A native Swift port of the [Fluid Framework](https://github.com/microsoft/FluidFramework) client,
version 3.11.0. A Swift client and a TypeScript client can edit the same document: Swift sends
the same ops and writes the same summaries, byte for byte, as the TypeScript packages from npm.
Every part is checked against those packages by a differential harness that runs TS and Swift
clients in one session and compares their state, events and summaries.

## Status

This is a prototype. It works for opening an existing document and editing it alongside TS
clients, on a local test service.

What works today:

- Loading an existing container with `OdspClient.getContainer`, `AzureClient.getContainer` (local
  mode, against tinylicious) or `TinyliciousClient.getContainer`, or through the loader with the
  ODSP, Routerlicious and tinylicious drivers.
- These DDSes, each checked against TS: SharedMap and SharedDirectory, SharedString (with
  intervals), SharedMatrix, SharedCounter, SharedCell, ConsensusRegisterCollection,
  SharedSummaryBlock, PactMap, TaskManager, ConsensusQueue, SharedArray and SharedSignal.
- Presence, resubmit of pending edits when a connection is re-established, and acting as the
  summarizing client.

What doesn't:

- Swift cannot create containers yet. A TS client has to create and attach the file first;
  Swift can then open it. `FluidContainer.create` and `uploadBlob` are not ported either.
- There is no SharedTree DDS. The SharedTree change family and forest storage formats are ported
  (`FluidTree`), but the DDS is not.
- The container does not reconnect on its own. After a dropped socket or a nack, the app calls
  `connect()` again. Storage requests are not retried on transient errors either.
- AzureClient's remote mode (Azure Fluid Relay) cannot load yet: the Routerlicious driver does not
  port service discovery or whole-summary upload.
- It has not been run against a production service. The ODSP driver matches the TS driver byte
  for byte against a local ODSP service, but it has never talked to real SharePoint.
- The public API mirrors the TS names and types (`IOdspTokenProvider`, `JSString`,
  `JSObject`). A Swift-native layer will be added on top, so expect the API to change.

Early performance numbers (macOS and the iOS Simulator, not a physical device) are in
[Benchmarks/RESULTS.md](Benchmarks/RESULTS.md).

## Platforms

iOS 18 and macOS 15 or later. The package uses Swift tools version 6.2 and is built and tested
with Swift 6.4.

## Adding the package

The repository is private, so your GitHub account needs access to it.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/jcfontecha/fluid-swift.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "FluidOdspClient", package: "fluid-swift"),
        .product(name: "FluidStatic", package: "fluid-swift"),
        .product(name: "FluidSequence", package: "fluid-swift"),
        .product(name: "FluidJS", package: "fluid-swift"),
    ]),
]
```

In Xcode, use File > Add Package Dependencies with the same URL. Each DDS is its own product
(`FluidMap`, `FluidSequence`, `FluidMatrix`, `FluidCounter`, and so on), as are the loader and
the drivers.

## Opening a container and editing a SharedString

A container and everything in it belong to one actor, which you pass as `isolation` when you open
it. An app passes `MainActor.shared` and then reads and edits its DDSes directly from MainActor
code. All DDS calls are synchronous, and events arrive as synchronous callbacks on that actor.
[ARCHITECTURE.md](ARCHITECTURE.md) section 2 explains why.

This example opens a file on the local ODSP service described below, whose tokens are
`storage:<user>` and `push:<user>`. Against SharePoint Embedded, your token provider returns real
access tokens instead.

```swift
import FluidJS
import FluidOdspClient
import FluidSequence
import FluidStatic

struct LocalTokenProvider: IOdspTokenProvider {
    let user: String

    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "storage:\(user)")
    }

    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "push:\(user)")
    }
}

struct MissingText: Error {}

@MainActor
func openNote(itemId: String) async throws -> FluidContainer {
    let client = OdspClient(properties: OdspClientProps(connection: OdspConnectionConfig(
        tokenProvider: LocalTokenProvider(user: "alice"),
        siteUrl: "http://localhost:7095",
        driveId: "b!bG9jYWwtb2RzcA",
        filePath: ""
    )))
    let schema = ContainerSchema(initialObjects: ["text": SharedString.self])
    let (container, _) = try await client.getContainer(
        itemId, containerSchema: schema, isolation: MainActor.shared)

    guard let text = container.initialObjects["text"] as? SharedString else {
        container.dispose()
        throw MissingText()
    }
    text.sequenceDelta = { [weak text] event in
        guard let text, !event.isLocal else { return }
        print("Remote edit. Text is now:", text.getText().description)
    }
    try text.insertText(0, JSString("Hello from Swift. "))
    return container
}
```

Positions and lengths in SharedString are UTF-16 offsets, as in TS. Keep the returned container
alive for as long as you edit the document, and call `dispose()` when you are done.

## Running the tests

```sh
swift test
```

The `OdspClientEndToEndTests` suite starts the local ODSP service and a TS client with Node, so
install the harness dependencies first (Node 22):

```sh
cd harness && npm ci
```

## Running the differential harness

The harness lives in `harness/`. It runs TS and Swift peers as separate processes and compares
them. Build the Swift peer before running Swift sessions:

```sh
swift build                    # from the repository root; builds .build/debug/fluid-swift-peer
cd harness
npm ci
npm run check                  # typecheck the harness
npm run fuzz -- --dds counter,map,directory --peers ts,swift --seeds 0..499
npm run replay -- traces/<file>.jsonl
```

There are more modes (`fuzz:mergetree`, `fuzz:presence`, `service`, `service:m4` and others) in
`harness/package.json`. [harness/README.md](harness/README.md) covers the basics, and
[harness/PROTOCOL.md](harness/PROTOCOL.md) gives the exact contract for each mode.

## Running FluidNotes against the local ODSP service

`Examples/FluidNotes` is a small iOS app that edits one SharedString. It uses the local ODSP
service in `harness/src/odsp-service`, which clients reach the same way they reach SharePoint
Embedded.

1. Start the service. It listens on port 7095 and prints its connection values:

   ```sh
   cd harness
   npm run odsp-service
   ```

2. Create a file with a TS client, since Swift cannot create one. This script creates a
   `{ text: SharedString }` container, types "TS: hello", prints `{"itemId": ...}` and keeps the
   document open until you press Ctrl-D:

   ```sh
   cd harness
   node --input-type=module --eval "$(cat ../Tests/FluidOdspClientTests/ts-text-client.mjs)" \
     http://localhost:7095 'b!bG9jYWwtb2RzcA' notes
   ```

3. Open `Examples/FluidNotes/FluidNotes.xcodeproj` (generated from `project.yml` with XcodeGen),
   run it in the iOS Simulator, tap Open and paste the item id.

`AppConfig.active` is set to the local service. To run on a device, replace `localhost` in
`AppConfig.local` with your Mac's `.local` hostname; the service already listens on all
interfaces.

## Architecture

[ARCHITECTURE.md](ARCHITECTURE.md) covers the design decisions: how correctness is defined by
the harness, the threading model, how JavaScript value semantics are reproduced, and how the
targets map to the TS packages.

## License

MIT. See [LICENSE](LICENSE). The port derives from Microsoft's FluidFramework, which is also MIT
licensed, and keeps its copyright notice.
