import assert from "node:assert/strict";
import {
  MockContainerRuntimeFactory,
  MockFluidDataStoreRuntime,
  MockSharedObjectServices,
  MockStorage,
} from "@fluidframework/test-runtime-utils/internal";
import { SharedString } from "@fluidframework/sequence/internal";

// Minimal upstream-only proof; no Session, protocol adapter, Swift, intervals or reconnect.
for (const v1 of [false, true]) {
  const factory = new MockContainerRuntimeFactory();
  const channels = ["A", "B", "summarizer"].map((clientId) => {
    const store = new MockFluidDataStoreRuntime({ clientId });
    store.options.newMergeTreeSnapshotFormat = v1;
    factory.createContainerRuntime(store);
    const channel = SharedString.getFactory().create(store, "text");
    const services = new MockSharedObjectServices({});
    services.deltaConnection = store.createDeltaConnection();
    channel.connect(services);
    return channel;
  });
  const [a, b, summarizer] = channels;
  assert(a && b && summarizer);
  a.insertText(0, "A");
  b.insertText(0, "B");
  factory.processAllMessages();
  assert.equal(a.getText(), b.getText());
  const summary = (await b.summarize()).summary;
  const store = new MockFluidDataStoreRuntime({ clientId: "loaded" });
  store.options.newMergeTreeSnapshotFormat = v1;
  factory.createContainerRuntime(store);
  const loaded = await SharedString.getFactory().load(store, "text", {
    objectStorage: MockStorage.createFromSummary(summary),
    deltaConnection: store.createDeltaConnection(),
  }, SharedString.getFactory().attributes);
  if (v1) assert.equal(loaded.getText(), b.getText());
  else assert.notEqual(loaded.getText(), b.getText());
  const readOnlySummary = (await summarizer.summarize()).summary;
  const readOnlyStore = new MockFluidDataStoreRuntime({ clientId: "loaded-summarizer" });
  readOnlyStore.options.newMergeTreeSnapshotFormat = v1;
  factory.createContainerRuntime(readOnlyStore);
  const readOnlyLoaded = await SharedString.getFactory().load(readOnlyStore, "text", {
    objectStorage: MockStorage.createFromSummary(readOnlySummary),
    deltaConnection: readOnlyStore.createDeltaConnection(),
  }, SharedString.getFactory().attributes);
  assert.equal(readOnlyLoaded.getText(), "BA");
  assert.equal(readOnlyLoaded.getText(), summarizer.getText());
  console.log(JSON.stringify({ format: v1 ? "v1" : "legacy", live: b.getText(), summarizerLoaded: readOnlyLoaded.getText(), loaded: loaded.getText(), summary }));
}
