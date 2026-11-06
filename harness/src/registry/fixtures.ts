// Golden channel-factory attributes for the Swift fluid-static registry
// (Tests/FluidStaticTests/Fixtures/channel-factories.json). Each entry is the
// SharedObjectKind's `getFactory()` type and `JSON.stringify(attributes)`.
import { writeFileSync } from "node:fs";
import { SharedCounter } from "@fluidframework/counter/internal";
import { SharedMap, SharedDirectory } from "@fluidframework/map/internal";
import { SharedCell } from "@fluidframework/cell/internal";
import { TaskManager } from "@fluidframework/task-manager/internal";
import { ConsensusRegisterCollection } from "@fluidframework/register-collection/internal";
import { ConsensusQueue } from "@fluidframework/ordered-collection/internal";
import { PactMap } from "@fluid-experimental/pact-map";
import { SharedSummaryBlock } from "@fluidframework/shared-summary-block/internal";
import { SharedArray, SharedSignal } from "@fluidframework/legacy-dds/internal";
import { SharedString } from "@fluidframework/sequence/internal";
import { SharedMatrix } from "@fluidframework/matrix/internal";
import type { IChannelFactory } from "@fluidframework/datastore-definitions/internal";

interface Kind {
  getFactory(): IChannelFactory;
}

const kinds: [string, unknown][] = [
  ["SharedMap", SharedMap],
  ["SharedDirectory", SharedDirectory],
  ["SharedCounter", SharedCounter],
  ["SharedCell", SharedCell],
  ["ConsensusRegisterCollection", ConsensusRegisterCollection],
  ["SharedSummaryBlock", SharedSummaryBlock],
  ["PactMap", PactMap],
  ["TaskManager", TaskManager],
  ["ConsensusQueue", ConsensusQueue],
  ["SharedArray", SharedArray],
  ["SharedSignal", SharedSignal],
  ["SharedString", SharedString],
  ["SharedMatrix", SharedMatrix],
];

const entries = kinds.map(([name, kind]) => {
  const factory = (kind as Kind).getFactory();
  return {
    name,
    type: factory.type,
    attributes: JSON.stringify(factory.attributes),
  };
});

const output = process.argv[2];
if (output === undefined) {
  throw new Error("usage: fixtures:registry <output.json>");
}
writeFileSync(output, `${JSON.stringify(entries, undefined, 2)}\n`);
