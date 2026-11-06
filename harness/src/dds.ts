import { MockHandle } from "@fluidframework/test-runtime-utils/internal";
import {
  isFluidHandle,
  encodeHandleForSerialization,
  toFluidHandleInternal,
} from "@fluidframework/runtime-utils/internal";

export function wireReplacer(_key: string, value: unknown): unknown {
  return isFluidHandle(value)
    ? encodeHandleForSerialization(toFluidHandleInternal(value))
    : value;
}
function canonicalValue(value: unknown): unknown {
  if (value === undefined) return { $fluid: "undefined" };
  return JSON.parse(JSON.stringify(value, wireReplacer));
}
function editValue(edit: Extract<Edit, { kind: "set" }>) {
  if (edit.valueKind === "undefined") return undefined;
  if (edit.valueKind === "handle")
    return new MockHandle(null, "/handles/a", "/handles/a");
  return edit.value;
}
import { z } from "zod";
import { SharedCounter } from "@fluidframework/counter/internal";
import { SharedMap, SharedDirectory } from "@fluidframework/map/internal";
import { SharedCell } from "@fluidframework/cell/internal";
import { TaskManager } from "@fluidframework/task-manager/internal";
import {
  ConsensusRegisterCollection,
  ReadPolicy,
} from "@fluidframework/register-collection/internal";
import {
  ConsensusQueue,
  ConsensusResult,
} from "@fluidframework/ordered-collection/internal";
import { PactMap } from "@fluid-experimental/pact-map";
import { SharedSummaryBlock } from "@fluidframework/shared-summary-block/internal";
import { SharedArray, SharedSignal } from "@fluidframework/legacy-dds/internal";
import type {
  IChannel,
  IChannelFactory,
  IChannelServices,
  IFluidDataStoreRuntime,
} from "@fluidframework/datastore-definitions/internal";
import type { Edit } from "./protocol.js";
import { Random } from "./random.js";

export const factories = {
  counter: SharedCounter.getFactory(),
  map: SharedMap.getFactory(),
  directory: SharedDirectory.getFactory(),
  cell: SharedCell.getFactory(),
  "task-manager": TaskManager.getFactory(),
  "register-collection": ConsensusRegisterCollection.getFactory(),
  "ordered-collection": ConsensusQueue.getFactory(),
  "pact-map": PactMap.getFactory(),
  "shared-summary-block": SharedSummaryBlock.getFactory(),
  "shared-array": SharedArray.getFactory(),
  "shared-signal": SharedSignal.getFactory(),
};
export type DDSName = keyof typeof factories;
export const names = Object.keys(factories) as DDSName[];
export interface Adapter {
  events: unknown[];
  channel: IChannel;
  edit(edit: Edit): void;
  state(): unknown;
  queries?(): unknown;
}
async function load<T extends IChannel>(
  factory: IChannelFactory<T>,
  store: IFluidDataStoreRuntime,
  id: string,
  services: IChannelServices,
  existing: boolean,
): Promise<T> {
  const channel = existing
    ? await factory.load(store, id, services, factory.attributes)
    : factory.create(store, id);
  if (!existing) channel.connect(services);
  return channel;
}
export async function createAdapter(
  name: DDSName,
  store: IFluidDataStoreRuntime,
  id: string,
  services: IChannelServices,
  existing: boolean,
): Promise<Adapter> {
  const events: unknown[] = [];
  const keys = ["a", "b", "c", "0", "10", "constructor"];
  switch (name) {
    case "counter": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("incremented", (amount, value) =>
        events.push(["incremented", amount, value]),
      );
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "increment") c.increment(e.amount);
          else throw Error("invalid edit");
        },
        state: () => ({ value: c.value }),
      };
    }
    case "map": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("valueChanged", (changed, local) =>
        events.push(["valueChanged", changed, local]),
      );
      c.on("clear", (local) => events.push(["clear", local]));
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "set") c.set(e.key, editValue(e));
          else if (e.kind === "delete") c.delete(e.key);
          else if (e.kind === "clear") c.clear();
          else throw Error("invalid edit");
        },
        state: () =>
          Array.from(
            c.entries(),
            ([key, value]) => [key, canonicalValue(value)] as const,
          ).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
      };
    }
    case "directory": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("valueChanged", (changed, local) =>
        events.push(["valueChanged", changed, local]),
      );
      c.on("clear", (local) => events.push(["clear", local]));
      c.on("cleared", (path, local) => events.push(["cleared", path, local]));
      c.on("containedValueChanged", (changed, local) =>
        events.push(["containedValueChanged", changed, local]),
      );
      c.on("subDirectoryCreated", (path, local) =>
        events.push(["subDirectoryCreated", path, local]),
      );
      c.on("subDirectoryDeleted", (path, local) =>
        events.push(["subDirectoryDeleted", path, local]),
      );
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "set")
            c.getWorkingDirectory(e.path ?? "/")?.set(e.key, editValue(e));
          else if (e.kind === "delete")
            c.getWorkingDirectory(e.path ?? "/")?.delete(e.key);
          else if (e.kind === "clear")
            c.getWorkingDirectory(e.path ?? "/")?.clear();
          else if (e.kind === "createSubDirectory")
            c.getWorkingDirectory(e.path)?.createSubDirectory(e.name);
          else if (e.kind === "deleteSubDirectory")
            c.getWorkingDirectory(e.path)?.deleteSubDirectory(e.name);
          else throw Error("invalid edit");
        },
        state: () => JSON.parse(JSON.stringify(directoryState(c))),
      };
    }
    case "cell": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("valueChanged", (value) => events.push(["valueChanged", value]));
      c.on("delete", () => events.push(["delete"]));
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "set") c.set(editValue(e));
          else if (e.kind === "delete") c.delete();
          else throw Error("invalid edit");
        },
        state: () => ({
          empty: c.empty(),
          value: c.empty() ? null : canonicalValue(c.get()),
        }),
      };
    }
    case "task-manager": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("assigned", (key) => events.push(["assigned", key]));
      c.on("lost", (key) => events.push(["lost", key]));
      c.on("completed", (key) => events.push(["completed", key]));
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "volunteer")
            void c.volunteerForTask(e.key).catch((error: Error) => {
              if (
                ![
                  "Disconnected before acquiring task assignment",
                  "Abandoned before acquiring task assignment",
                ].includes(error.message)
              )
                throw error;
            });
          else if (e.kind === "subscribe") c.subscribeToTask(e.key);
          else if (e.kind === "abandon") c.abandon(e.key);
          else if (e.kind === "complete") {
            // The upstream reducer tolerates only this completion failure.
            try {
              c.complete(e.key);
            } catch (error: unknown) {
              if (
                !(error instanceof Error) ||
                error.message !==
                  "Attempted to complete task in disconnected state"
              )
                throw error;
            }
          } else throw Error("invalid edit");
        },
        state: async () => {
          const summary = (await c.summarize()).summary;
          const blob = summary.tree.header;
          if (!blob || blob.type !== 2 || typeof blob.content !== "string")
            throw Error("Missing task header");
          return z
            .array(z.tuple([z.string(), z.array(z.string())]))
            .parse(JSON.parse(blob.content))
            .sort(([a], [b]) => a.localeCompare(b));
        },
        queries: () => ({
          canVolunteer: c.canVolunteer(),
          tasks: taskIdPool.map((key) => ({
            key,
            assigned: c.assigned(key),
            queued: c.queued(key),
            subscribed: c.subscribed(key),
          })),
        }),
      };
    }
    case "register-collection": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("atomicChanged", (key, value, local) =>
        events.push(["atomicChanged", key, value, local]),
      );
      c.on("versionChanged", (key, value, local) =>
        events.push(["versionChanged", key, value, local]),
      );
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "set") void c.write(e.key, e.value);
          else throw Error("invalid edit");
        },
        // Sorted: keys() order is not a cross-replica invariant. The summary is a plain object,
        // so a loaded replica enumerates array-index keys first; a live one keeps arrival order.
        state: () =>
          c
            .keys()
            .sort()
            .map((k) => [
              k,
              c.read(k, ReadPolicy.Atomic),
              c.read(k, ReadPolicy.LWW),
              c.readVersions(k),
            ]),
        // keys() order, checked against the twin only (assertEqualConsensusRegisterCollections).
        queries: () => ({ keys: c.keys() }),
      };
    }
    case "ordered-collection": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("add", (value, fresh) => events.push(["add", value, fresh]));
      c.on("acquire", (value, id) => events.push(["acquire", value, id]));
      c.on("complete", (value) => events.push(["complete", value]));
      c.on("localRelease", (value, intentional) =>
        events.push(["localRelease", value, intentional]),
      );
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "add") void c.add(e.value);
          else if (e.kind === "acquire")
            void c.acquire(async () =>
              e.result === "release"
                ? ConsensusResult.Release
                : ConsensusResult.Complete,
            );
          else throw Error("invalid edit");
        },
        state: async () => {
          const summary = (await c.summarize()).summary;
          const header = summary.tree.header;
          const tracking = summary.tree.jobTracking;
          if (
            !header ||
            header.type !== 2 ||
            typeof header.content !== "string" ||
            !tracking ||
            tracking.type !== 2 ||
            typeof tracking.content !== "string"
          )
            throw Error("Missing queue blobs");
          return {
            available: JSON.parse(header.content),
            acquired: z
              .array(z.tuple([z.string(), z.json()]))
              .parse(JSON.parse(tracking.content))
              .sort(([a], [b]) => a.localeCompare(b)),
          };
        },
      };
    }
    case "pact-map": {
      const c = await load(factories[name], store, id, services, existing);
      for (const event of ["pending", "accepted"] as const)
        c.on(event, (key) => events.push([event, key]));
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "set") c.set(e.key, editValue(e));
          else if (e.kind === "delete") c.delete(e.key);
          else throw Error("invalid edit");
        },
        state: () =>
          keys.map((key) => ({
            key,
            value: c.get(key),
            details: c.getWithDetails(key),
            pending: c.isPending(key),
            proposal: c.getPending(key),
          })),
      };
    }
    case "shared-summary-block": {
      const c = await load(factories[name], store, id, services, existing);
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "set") c.set(e.key, e.value);
          else throw Error("invalid edit");
        },
        state: () => keys.map((key) => [key, c.get(key)]),
      };
    }
    case "shared-array": {
      const c = await load(factories[name], store, id, services, existing);
      // Entry-ID bookkeeping exactly as legacy-dds/src/test/array/fuzzUtils.ts tracks it; the
      // generator chooses toggle and toggleMove targets from it, as upstream does.
      const insertIds = new Map<string, unknown>();
      const deleteIds = new Map<string, unknown>();
      const moveIds = new Map<string, string>();
      c.on("valueChanged", (op, local) => {
        events.push(["valueChanged", op, local]);
        switch (op.type) {
          case 0:
            insertIds.set(op.entryId, op.value);
            deleteIds.delete(op.entryId);
            break;
          case 1:
            deleteIds.set(op.entryId, insertIds.get(op.entryId));
            insertIds.delete(op.entryId);
            moveIds.delete(op.entryId);
            break;
          case 2:
            if (insertIds.has(op.entryId)) {
              insertIds.set(op.changedToEntryId, insertIds.get(op.entryId));
              insertIds.delete(op.entryId);
              moveIds.set(op.entryId, op.changedToEntryId);
            }
            break;
          case 3:
            if (insertIds.has(op.entryId)) {
              deleteIds.set(op.entryId, insertIds.get(op.entryId));
              insertIds.delete(op.entryId);
              moveIds.delete(op.entryId);
            } else {
              insertIds.set(op.entryId, deleteIds.get(op.entryId));
              deleteIds.delete(op.entryId);
            }
            break;
          case 4:
            insertIds.set(op.entryId, insertIds.get(op.changedToEntryId));
            insertIds.delete(op.changedToEntryId);
            moveIds.delete(op.changedToEntryId);
            moveIds.set(op.changedToEntryId, op.entryId);
            break;
        }
      });
      return {
        events,
        channel: c,
        // The upstream reducer: operations apply exactly as generated.
        edit: (e) => {
          if (e.kind === "insert") c.insert(e.index ?? 0, z.string().parse(e.value));
          else if (e.kind === "delete") c.delete(e.index ?? 0);
          else if (e.kind === "move") c.move(e.oldIndex, e.newIndex);
          else if (e.kind === "toggle") c.toggle(e.entryId);
          else if (e.kind === "toggleMove") c.toggleMove(e.oldEntryId, e.newEntryId);
          else if (e.kind === "insertBulkAfter")
            c.insertBulkAfter(
              e.ref === undefined ? undefined : z.string().parse(e.ref),
              z.array(z.string()).parse(e.values),
            );
          else throw Error("invalid edit");
        },
        state: () => c.get(),
        queries: () => ({
          length: c.get().length,
          values: c.get(),
          insertIds: [...insertIds.keys()],
          deleteIds: [...deleteIds.keys()],
          moveIds: [...moveIds],
        }),
      };
    }
    case "shared-signal": {
      const c = await load(factories[name], store, id, services, existing);
      c.on("notify", (value, local) => events.push(["notify", value, local]));
      return {
        events,
        channel: c,
        edit: (e) => {
          if (e.kind === "notify") c.notify(e.value);
          else throw Error("invalid edit");
        },
        state: () => ({ persistent: false }),
      };
    }
  }
}
import type { IDirectory } from "@fluidframework/map/internal";
function directoryState(c: IDirectory): unknown {
  return {
    entries: Array.from(
      c.entries(),
      ([key, value]) => [key, canonicalValue(value)] as const,
    ).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
    children: Array.from(c.subdirectories(), ([name, child]) => [
      name,
      directoryState(child),
    ]),
  };
}
/** DDSes whose generator chooses operations from the client's own `queries`. */
export const queryDrivenGenerators: readonly DDSName[] = [
  "task-manager",
  "shared-array",
];

const taskManagerQueries = z.object({
  canVolunteer: z.boolean(),
  tasks: z.array(
    z.object({
      key: z.string(),
      assigned: z.boolean(),
      queued: z.boolean(),
      subscribed: z.boolean(),
    }),
  ),
});
const sharedArrayQueries = z.object({
  length: z.number().int().nonnegative(),
  values: z.array(z.string()),
  insertIds: z.array(z.string()),
  deleteIds: z.array(z.string()),
  moveIds: z.array(z.tuple([z.string(), z.string()])),
});

/** `createWeightedGenerator`: a weighted choice among the eligible options. */
function weighted<T>(
  r: Random,
  options: readonly (readonly [() => T, number, boolean])[],
): T {
  const eligible = options.filter(([, , accepted]) => accepted);
  const total = eligible.reduce((sum, [, weight]) => sum + weight, 0);
  let choice = r.int(total);
  for (const [make, weight] of eligible) {
    if (choice < weight) return make();
    choice -= weight;
  }
  throw new Error("No eligible operation");
}

/** `random.string(length)` over lowercase letters. */
function randomString(r: Random, length: number): string {
  let result = "";
  for (let i = 0; i < length; i++)
    result += String.fromCharCode(97 + r.int(26));
  return result;
}

/** `random.integer(min, max)`, both inclusive. */
function integer(r: Random, min: number, max: number): number {
  return min + r.int(max - min + 1);
}

// Fixed pools, as upstream draws them from makeRandom(0) once per generator.
const taskIdPool = ["a", "b", "c"];
const registerKeyPool = ["a", "b", "c", "0", "10"];
const queueValuePool = ["qvalu", "rvalu", "svalu"];

/**
 * One operation for `name`. Where upstream (`packages/dds/<dds>/src/test/fuzzUtils.ts`) defines a
 * fuzz model, this follows its operations, weights and acceptance conditions; `queries` is the
 * acting client's own `queries` result, required by `queryDrivenGenerators`.
 */
export function generate(name: DDSName, r: Random, queries?: unknown): Edit {
  const key = r.pick(["a", "b", "c", "0", "10", "constructor"]);
  const value = r.int(5) === 0 ? "x".repeat(8200) : r.int(1000);
  const p = r.int(10);
  switch (name) {
    case "counter":
      return { kind: "increment", amount: r.int(201) - 100 };
    case "map":
      return p < 6
        ? mapEdit(key, value, r)
        : p < 9
          ? { kind: "delete", key }
          : { kind: "clear" };
    case "directory": {
      const path = r.pick(["/", "/one", "/two"]);
      return p < 5
        ? { ...mapEdit(key, value, r), path }
        : p < 7
          ? { kind: "delete", key, path }
          : p === 7
            ? { kind: "clear", path }
            : p === 8
              ? {
                  kind: "createSubDirectory",
                  path: "/",
                  name: r.pick(["one", "two", "three"]),
                }
              : {
                  kind: "deleteSubDirectory",
                  path: "/",
                  name: r.pick(["one", "two", "three"]),
                };
    }
    case "cell":
      // cell.spec.ts sets plain values and handles; a cell never holds undefined.
      return p < 7 ? cellEdit(key, value, r) : { kind: "delete", key };
    case "register-collection":
      // register-collection fuzzUtils: write only, 5 keys, 5-character values.
      return {
        kind: "set",
        key: r.pick(registerKeyPool),
        value: randomString(r, 5),
      };
    case "shared-summary-block":
      return { kind: "set", key, value };
    case "pact-map":
      // pactMap.spec.ts: set (undefined is a delete proposal) and delete. No handles: PactMap
      // summarizeCore uses plain JSON.stringify, so it cannot serialize them.
      return p < 7 ? pactEdit(key, value, r) : { kind: "delete", key };
    case "task-manager": {
      // task-manager fuzzUtils: pick a task, then an eligible operation, all weighted 1.
      const state = taskManagerQueries.parse(queries);
      const taskId = r.pick(taskIdPool);
      const task = state.tasks.find((t) => t.key === taskId);
      if (!task) throw new Error(`Missing task ${taskId} in queries`);
      return weighted<Edit>(r, [
        [() => ({ kind: "volunteer", key: taskId }), 1, state.canVolunteer],
        [() => ({ kind: "abandon", key: taskId }), 1, task.queued],
        [() => ({ kind: "subscribe", key: taskId }), 1, true],
        [() => ({ kind: "complete", key: taskId }), 1, task.assigned],
      ]);
    }
    case "ordered-collection":
      // ordered-collection fuzzUtils: add and acquire weighted 1:1, 3 values.
      return r.int(2) === 0
        ? { kind: "add", value: r.pick(queueValuePool) }
        : { kind: "acquire", result: r.pick(["complete", "release"]) };
    case "shared-array":
      return arrayEdit(r, sharedArrayQueries.parse(queries));
    case "shared-signal":
      return { kind: "notify", value };
  }
}

/** legacy-dds/src/test/array/fuzzUtils.ts makeSharedArrayOperationGenerator, default weights. */
function arrayEdit(
  r: Random,
  state: z.infer<typeof sharedArrayQueries>,
): Edit {
  const length = state.length;
  // Upstream conditions index-based operations on insertIds alone, but that bookkeeping can drift
  // (non-empty insertIds over an empty array), which makes delete(0) throw. Also require entries.
  const hasEnoughInsertLength = state.insertIds.length > 0 && length > 0;
  const hasEnoughToggleLength =
    state.insertIds.length + state.deleteIds.length > 0;
  const hasEnoughMoveLength = state.moveIds.length > 2;
  return weighted<Edit>(r, [
    [
      () => ({
        kind: "insert",
        index: integer(r, 0, length),
        value: randomString(r, integer(r, 1, 5)),
      }),
      5,
      true,
    ],
    [
      () => ({
        kind: "delete",
        index: integer(r, 0, Math.max(0, length - 1)),
        key: "",
      }),
      3,
      hasEnoughInsertLength,
    ],
    [
      () => ({
        kind: "move",
        oldIndex: integer(r, 0, Math.max(0, length - 1)),
        newIndex: integer(r, 0, length),
      }),
      3,
      hasEnoughInsertLength,
    ],
    [
      () => {
        const ref = state.values[integer(r, 0, Math.max(0, length - 1))];
        const values = Array.from({ length: integer(r, 1, 5) }, () =>
          randomString(r, integer(r, 1, 5)),
        );
        return ref === undefined
          ? { kind: "insertBulkAfter", values }
          : { kind: "insertBulkAfter", ref, values };
      },
      1,
      hasEnoughInsertLength,
    ],
    [
      () => ({
        kind: "toggle",
        entryId: r.pick([...state.insertIds, ...state.deleteIds]),
      }),
      1,
      hasEnoughToggleLength,
    ],
    [
      () => {
        const [oldEntryId, newEntryId] = r.pick(state.moveIds);
        return { kind: "toggleMove", oldEntryId, newEntryId };
      },
      1,
      hasEnoughMoveLength,
    ],
  ]);
}

function pactEdit(
  key: string,
  value: string | number,
  r: Random,
): Extract<Edit, { kind: "set" }> {
  return r.int(8) === 0
    ? { kind: "set", key, value: null, valueKind: "undefined" }
    : { kind: "set", key, value };
}

function cellEdit(
  key: string,
  value: string | number,
  r: Random,
): Extract<Edit, { kind: "set" }> {
  return r.int(4) === 0
    ? {
        kind: "set",
        key,
        value: { type: "__fluid_handle__", url: "/handles/a" },
        valueKind: "handle",
      }
    : { kind: "set", key, value };
}

function mapEdit(
  key: string,
  value: string | number,
  r: Random,
): Extract<Edit, { kind: "set" }> {
  const kind = r.int(8);
  if (kind === 0)
    return { kind: "set", key, value: null, valueKind: "undefined" };
  if (kind === 1)
    return {
      kind: "set",
      key,
      value: { type: "__fluid_handle__", url: "/handles/a" },
      valueKind: "handle",
    };
  return { kind: "set", key, value };
}
