// `npm run fuzz:presence -- --self`      two independent runs of the real TS presence runtime must agree.
// `npm run fuzz:presence`                Swift peer (FluidPresencePeer) versus the TS oracle, byte for byte.
// Options: --seeds=N (default 1000), --scratch-path=DIR (default .build/h9).

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { Random } from "../random.js";
import { run } from "./oracle.js";
import type { Command, ManagerType, NetworkEntry, Scenario, SchemaEntry } from "./scenario.js";

const root = resolve(import.meta.dirname, "../../..");

const delays = [0, 0, 0, 1, 2, 5, 10, 20, 50, 120, 300, 700];
const advances = [0, 1, 5, 20, 60, 100, 250, 1000, 5000, 31000];
const statesAddresses = ["app:cursor", "app:cells", "room:a"];
const notificationAddresses = ["app:events", "room:chat"];
const labels = ["a", "b", "c"];

interface SlotPlan {
  created: boolean;
  connected: boolean;
  // `${space}:${address}` -> key -> type
  registered: Map<string, Map<string, ManagerType>>;
}

function latestValue(r: Random): unknown {
  switch (r.int(8)) {
    case 0:
      return null;
    case 1:
      return { x: "not a number" };
    case 2:
      return {};
    default:
      return { x: r.int(100) + (r.int(4) === 0 ? 0.5 : 0), label: r.pick(labels) };
  }
}

function mapValue(r: Random): unknown {
  return r.int(5) === 0 ? { x: "bad" } : { x: r.int(100) };
}

// Random.pick rejects undefined elements, so absence is encoded as -1.
function optionalNumber(r: Random, items: readonly number[]): number | undefined {
  const value = r.pick(items);
  return value < 0 ? undefined : value;
}

function schemaEntry(r: Random, space: string): SchemaEntry {
  if (space === "notifications") {
    return { key: r.pick(["msgs", "alerts"]), type: "notifications", subscriptions: r.pick([[], ["ping"], ["ping", "pong"]]) };
  }
  const latency = optionalNumber(r, [-1, -1, 0, 30, 200]);
  const withLatency = latency === undefined ? {} : { latency };
  switch (r.int(4)) {
    case 0:
      return { key: "pos", type: "latest", local: latestValue(r), ...withLatency };
    case 1:
      return { key: "sel", type: "latest", local: latestValue(r), validated: true, ...withLatency };
    case 2:
      return {
        key: "cells",
        type: "latestMap",
        local: r.int(2) === 0 ? { a: mapValue(r) } : {},
        ...withLatency,
      };
    default:
      return {
        key: "vcells",
        type: "latestMap",
        local: { b: mapValue(r), badkey: mapValue(r) },
        validated: true,
        keyValidated: true,
        ...withLatency,
      };
  }
}

function canonicalSchema(address: string, r: Random): SchemaEntry[] {
  switch (address) {
    case "app:cursor":
      return [
        { key: "pos", type: "latest", local: latestValue(r) },
        { key: "sel", type: "latest", local: { x: r.int(100) }, validated: true },
      ];
    case "app:cells":
      return [
        { key: "cells", type: "latestMap", local: r.int(2) === 0 ? { a: mapValue(r) } : {} },
        { key: "vcells", type: "latestMap", local: { b: mapValue(r) }, validated: true, keyValidated: true },
      ];
    case "room:a":
      return [
        { key: "pos", type: "latest", local: latestValue(r), latency: 30 },
        { key: "cells", type: "latestMap", local: {} },
      ];
    case "room:chat":
      return [
        { key: "msgs", type: "notifications", subscriptions: ["ping"] },
        { key: "alerts", type: "notifications", subscriptions: [] },
      ];
    default:
      return [{ key: "msgs", type: "notifications", subscriptions: ["ping", "pong"] }];
  }
}

export function generate(seed: number): Scenario {
  const r = new Random(seed);
  const slots = 2 + r.int(3);
  const network: NetworkEntry[] = Array.from({ length: 64 }, () => ({
    delay: r.pick(delays),
    drop: r.int(100) < 6,
  }));
  const randoms = Array.from({ length: 16 }, () => r.uint32() / 0x100000000);
  const commands: Command[] = [];
  const plans: SlotPlan[] = Array.from({ length: slots }, () => ({
    created: false,
    connected: false,
    registered: new Map(),
  }));

  const register = (slot: number, forcedSpace?: string): void => {
    const space = forcedSpace ?? (r.int(3) === 0 ? "notifications" : "states");
    const address = r.pick(space === "states" ? statesAddresses : notificationAddresses);
    // Mostly the shared per-address schema, so registrations on different slots overlap;
    // sometimes a random one (including type conflicts that make getWorkspace throw).
    const schema =
      r.int(10) < 6
        ? canonicalSchema(address, r)
        : Array.from({ length: 1 + r.int(2) }, () => schemaEntry(r, space));
    const command: Command = { kind: "workspace", slot, space, address, schema };
    if (space === "states" && r.int(3) === 0) {
      command.latency = r.pick([0, 30, 100]);
    }
    commands.push(command);
    const id = `${space}:${address}`;
    const keys = plans[slot]?.registered.get(id) ?? new Map<string, ManagerType>();
    for (const entry of schema) {
      if (!keys.has(entry.key)) {
        keys.set(entry.key, entry.type);
      }
    }
    plans[slot]?.registered.set(id, keys);
  };

  for (let slot = 0; slot < slots; slot += 1) {
    commands.push({ kind: "create", slot });
    plans[slot]!.created = true;
  }
  // Some slots register before their first connection (initial data while disconnected).
  for (let slot = 0; slot < slots; slot += 1) {
    if (r.int(3) === 0) {
      register(slot);
    }
  }

  const connect = (slot: number): void => {
    commands.push({ kind: "connect", slot, write: r.int(10) < 7, interactive: r.int(10) < 9 });
    plans[slot]!.connected = true;
  };
  connect(0);
  commands.push({ kind: "advance", ms: r.pick(advances) });

  const steps = 25 + r.int(25);
  for (let step = 0; step < steps; step += 1) {
    const slot = r.int(slots);
    const plan = plans[slot]!;
    const choice = r.int(100);
    if (choice < 14) {
      commands.push({ kind: "advance", ms: r.pick(advances) });
    } else if (choice < 24) {
      if (!plan.connected) {
        connect(slot);
      }
    } else if (choice < 29) {
      if (plan.connected && plans.filter((p) => p.connected).length > 1) {
        commands.push({ kind: "disconnect", slot });
        plan.connected = false;
      }
    } else if (choice < 42) {
      register(slot);
    } else if (choice < 46) {
      const space = r.int(3) === 0 ? "notifications" : "states";
      commands.push({
        kind: "arm",
        slot,
        space,
        address: r.pick(space === "states" ? statesAddresses : notificationAddresses),
        schema: [schemaEntry(r, space)],
      });
    } else if (choice < 96) {
      const registered = [...plan.registered.entries()];
      if (registered.length === 0) {
        continue;
      }
      const [id, keys] = r.pick(registered);
      const space = id.startsWith("states:") ? "states" : "notifications";
      const address = id.slice(space.length + 1);
      const [key, type] = r.pick([...keys.entries()]);
      const base = { slot, space, address, key };
      if (type === "latest") {
        commands.push({ kind: "set", ...base, value: latestValue(r) });
      } else if (type === "latestMap") {
        const mapKey = r.pick(["a", "b", "c", "badkey"]);
        const which = r.int(30);
        if (which < 18) {
          commands.push({ kind: "mapSet", ...base, mapKey, value: mapValue(r) });
        } else if (which < 29) {
          commands.push({ kind: "mapDelete", ...base, mapKey });
        } else {
          commands.push({ kind: "mapClear", ...base });
        }
      } else if (r.int(4) === 0) {
        commands.push({ kind: "controls", ...base, latency: r.pick([0, 50]) });
      } else {
        const command: Command = {
          ...base,
          kind: "notify",
          name: r.pick(["ping", "pong", "other"]),
          args: [r.int(10), r.pick(labels)],
        };
        if (r.int(4) === 0) {
          command.target = r.int(slots);
        }
        commands.push(command);
      }
    } else {
      const from = `c${r.int(slots)}.0`;
      const kind = r.int(6);
      const base = { kind: "inject", slot, from, local: r.int(4) === 0 };
      if (kind === 0) {
        commands.push({ ...base, addressChain: [], message: { type: "Pres:Ack", content: { id: "ack-1" } } });
      } else if (kind === 1) {
        commands.push({ ...base, addressChain: ["?"], message: { type: "Pres:Future", content: {} } });
      } else if (kind === 2) {
        commands.push({ ...base, addressChain: [], message: { type: "Pres:Future", content: {} } });
      } else if (kind === 3) {
        commands.push({
          ...base,
          addressChain: [],
          message: {
            type: "Pres:DatastoreUpdate",
            content: {
              sendTimestamp: 1_000_000,
              avgLatency: 0,
              acknowledgementId: "ack-2",
              data: { "system:presence": { clientToSessionId: {} } },
            },
          },
        });
      } else {
        commands.push({ kind: "controls", slot, space: "states", address: "app:cursor", refresh: optionalNumber(r, [-1, 5, 10, 50]) });
      }
    }
  }
  commands.push({ kind: "advance", ms: 40000 });
  return { seed, slots, network, randoms, commands };
}

function coverage(trace: string): Map<string, number> {
  const counts = new Map<string, number>();
  const bump = (name: string): void => {
    counts.set(name, (counts.get(name) ?? 0) + 1);
  };
  for (const row of JSON.parse(trace) as Record<string, unknown>[]) {
    if (typeof row.ev === "string") {
      bump(`event:${row.ev}`);
    }
    if (typeof row.error === "string") {
      bump(`error:${row.error}`);
    }
    if ("validate" in row) {
      bump("validate");
    }
    const signal = row.signal as { type?: string; content?: Record<string, unknown> } | undefined;
    if (signal !== undefined) {
      bump(`signal:${signal.type}`);
      if (signal.content?.isComplete === true) {
        bump("signal:complete");
      }
      if (signal.content?.joinResponseFor !== undefined) {
        bump("signal:joinResponseFor");
      }
    }
  }
  return counts;
}

const requiredCoverage = [
  "signal:Pres:ClientJoin",
  "signal:Pres:DatastoreUpdate",
  "signal:complete",
  "signal:joinResponseFor",
  "event:attendeeConnected",
  "event:attendeeDisconnected",
  "event:remoteUpdated",
  "event:remoteItemUpdated",
  "event:remoteItemRemoved",
  "event:localUpdated",
  "event:localItemUpdated",
  "event:workspaceActivated",
  "event:notification",
  "event:unattended",
  "validate",
  "error:processSignal",
  "error:mapClear",
];

const self = process.argv.includes("--self");
const count = Number(process.argv.find((a) => a.startsWith("--seeds="))?.split("=")[1] ?? 1000);
const scratchPath =
  process.argv.find((a) => a.startsWith("--scratch-path="))?.slice("--scratch-path=".length) ?? ".build/h9";

if (!self) {
  execFileSync("swift", ["build", "--scratch-path", scratchPath, "--product", "FluidPresencePeer", "-c", "release"], {
    cwd: root,
    stdio: "inherit",
  });
}
const child = self
  ? undefined
  : spawn(resolve(root, scratchPath, "release/FluidPresencePeer"), [], { stdio: ["pipe", "pipe", "inherit"] });
const lines = child === undefined ? undefined : createInterface({ input: child.stdout })[Symbol.asyncIterator]();

const totals = new Map<string, number>();
try {
  for (let seed = 0; seed < count; seed += 1) {
    const scenario = generate(seed);
    const expected = run(scenario);
    for (const [name, value] of coverage(expected)) {
      totals.set(name, (totals.get(name) ?? 0) + value);
    }
    let actual: string;
    if (child === undefined || lines === undefined) {
      actual = run(scenario);
    } else {
      child.stdin.write(`${JSON.stringify(scenario)}\n`);
      let timer: NodeJS.Timeout | undefined;
      const line = await Promise.race([
        lines.next(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            reject(new Error("peer timeout"));
          }, 30000);
        }),
      ]).finally(() => {
        clearTimeout(timer);
      });
      assert(!line.done, "peer exited");
      actual = line.value;
    }
    if (actual !== expected) {
      mkdirSync(resolve(root, "harness/traces/presence"), { recursive: true });
      writeFileSync(
        resolve(root, `harness/traces/presence/${seed}.json`),
        JSON.stringify({ scenario, expected: JSON.parse(expected), actual: JSON.parse(actual) }, null, 2),
      );
    }
    assert.equal(actual, expected, `seed ${seed}`);
  }
  for (const name of requiredCoverage) {
    assert((totals.get(name) ?? 0) > 0, `generator never exercised ${name}`);
  }
  console.log(`Presence ${self ? "TS self-check" : "Swift differential"}: ${count} seeds passed`);
  console.log([...totals.entries()].map(([name, value]) => `${name}=${value}`).join(" "));
} finally {
  child?.kill();
}
