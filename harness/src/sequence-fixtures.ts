import { mkdir, writeFile } from "node:fs/promises";
import { AttachState } from "@fluidframework/container-definitions";
import { Side, ReferenceType } from "@fluidframework/merge-tree/internal";
import { SharedString } from "@fluidframework/sequence/internal";
import { MockFluidDataStoreRuntime } from "@fluidframework/test-runtime-utils/internal";

// Upstream-authored, byte-exact detached summary fixtures. No native implementation participates.
const fixtures = [];
for (const v1 of [false, true]) {
  for (const intervalFormat of ["1", "2"] as const) {
    for (const scenario of ["empty", "unicode", "chunks", "intervals"]) {
      const runtime = new MockFluidDataStoreRuntime({ attachState: AttachState.Detached });
      runtime.options = {
        newMergeTreeSnapshotFormat: v1,
        intervalSerializationFormat: intervalFormat,
        intervalStickinessEnabled: true,
        mergeTreeReferencesCanSlideToEndpoint: true,
      };
      const channel = SharedString.getFactory().create(runtime, "text");
      if (scenario === "unicode") {
        channel.insertText(0, "A😀B", { color: "red", absent: null });
        channel.removeRange(1, 2);
        channel.insertMarker(1, ReferenceType.Tile, { referenceTileLabels: ["paragraph"] });
      } else if (scenario === "chunks") {
        for (let block = 0; block < 5; block++) {
          channel.insertText(channel.getLength(), String(block).repeat(6000), { block });
        }
      } else if (scenario === "intervals") {
        channel.insertText(0, "abcdefgh");
        const collection = channel.getIntervalCollection("comments");
        const whole = { id: "whole", start: "start", end: "end", props: { color: "red" } } as const;
        collection.add(whole);
        const none = { id: "none", start: { pos: 2, side: Side.Before }, end: { pos: 5, side: Side.After } };
        collection.add(none);
        channel.getIntervalCollection("0");
      }
      fixtures.push({ scenario, v1, intervalFormat, summary: (await channel.summarize()).summary,
        text: Array.from({ length: channel.getText().length }, (_, index) => channel.getText().charCodeAt(index)) });
    }
  }
}
const folder = new URL("../../Tests/FluidSequenceTests/Fixtures/", import.meta.url);
await mkdir(folder, { recursive: true });
await writeFile(new URL("summaries.json", folder), JSON.stringify(fixtures));
console.log(`Wrote ${fixtures.length} upstream summary fixtures`);
