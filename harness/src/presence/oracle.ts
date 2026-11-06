// TS oracle for the presence differential harness: the real @fluid-internal/presence-runtime
// 3.11.0 `createPresenceManager` on simulated clients, joined by a driver-owned signal bus.
// `run(scenario)` returns the trace as one JSON string; the Swift peer must produce the same string.

import { createPresenceManager } from "../../node_modules/@fluid-internal/presence-runtime/lib/runtime/presenceManager.js";
import type { IEphemeralRuntime } from "../../node_modules/@fluid-internal/presence-runtime/lib/runtime/runtimeTypes.js";
import { Notifications, StateFactory } from "@fluid-internal/presence-runtime/states";
import { MockAudience, MockQuorumClients } from "@fluidframework/test-runtime-utils/internal";
import { FakeClock } from "./clock.js";
import { startTime, type Command, type Scenario, type SchemaEntry } from "./scenario.js";

type Row = Record<string, unknown>;
type Presence = ReturnType<typeof createPresenceManager>;
type Attendee = ReturnType<Presence["attendees"]["getMyself"]>;

// Dynamic view of a workspace. The real API is schema-generic, the harness picks the
// schema at run time.
interface Accessor {
  (): unknown;
}
interface LatestManager {
  local: unknown;
  controls: { allowableUpdateLatencyMs: number | undefined; forcedRefreshIntervalMs: number | undefined };
  events: { on(event: string, listener: (payload: Record<string, unknown>) => void): () => void };
  getRemotes(): IterableIterator<{ attendee: Attendee; value: unknown; metadata: { revision: number; timestamp: number } }>;
  getStateAttendees(): Attendee[];
  getRemote(attendee: Attendee): { value: unknown; metadata: { revision: number; timestamp: number } };
}
interface LatestMapManager {
  local: {
    size: number;
    keys(): IterableIterator<string>;
    get(key: string): unknown;
    set(key: string, value: unknown): unknown;
    delete(key: string): boolean;
    clear(): void;
  };
  controls: LatestManager["controls"];
  events: LatestManager["events"];
  getRemotes(): IterableIterator<{ attendee: Attendee; items: Map<string, { value: unknown; metadata: { revision: number; timestamp: number } }> }>;
  getStateAttendees(): Attendee[];
  getRemote(attendee: Attendee): Map<string, { value: unknown; metadata: { revision: number; timestamp: number } }>;
}
interface NotificationsManager {
  events: { on(event: string, listener: (...args: unknown[]) => void): () => void };
  notifications: { on(name: string, listener: (...args: unknown[]) => void): () => void };
  emit: {
    broadcast(name: string, ...args: unknown[]): void;
    unicast(name: string, target: Attendee, ...args: unknown[]): void;
  };
}
interface Workspace {
  controls: { allowableUpdateLatencyMs: number | undefined; forcedRefreshIntervalMs: number | undefined };
  states: Record<string, unknown>;
}
interface PresenceApi {
  states: { getWorkspace(address: string, schema: Record<string, unknown>, settings?: { allowableUpdateLatencyMs: number }): Workspace };
  notifications: { getWorkspace(address: string, schema: Record<string, unknown>): Workspace };
  events: { on(event: "workspaceActivated", listener: (address: string, type: string) => void): () => void };
}

interface ServiceMember {
  connectionId: string;
  slot: number;
  write: boolean;
  interactive: boolean;
  sequenceNumber: number | undefined;
}

interface Slot {
  index: number;
  attendeeId: string;
  runtime: SlotRuntime | undefined;
  presence: Presence | undefined;
  connectionCount: number;
  workspaces: Map<string, { space: string; address: string; types: Map<string, string>; workspace: Workspace }>;
  subscribed: Set<string>;
  armed: Map<string, Command>;
}

function clientDetails(write: boolean, interactive: boolean, name: string): Record<string, unknown> {
  return {
    mode: write ? "write" : "read",
    details: { capabilities: { interactive } },
    permission: [],
    user: { id: name },
    scopes: [],
  };
}

class SlotRuntime {
  public clientId: string | undefined;
  public joined = false;
  public readonly audience = new MockAudience();
  public readonly quorum = new MockQuorumClients();
  public readonly disconnectedListeners: (() => void)[] = [];
  public readonly supportedFeatures: ReadonlySet<string> = new Set(["submit_signals_v2"]);
  public readonly logger = { send(): void {} };
  public readonly events = {
    on: (event: string, listener: () => void): unknown => {
      if (event === "disconnected") {
        this.disconnectedListeners.push(listener);
      }
      return this;
    },
    off: (): unknown => this,
  };

  public constructor(private readonly onSubmit: (message: unknown) => void) {}

  public getJoinedStatus = (): "disconnected" | "joinedForReading" =>
    this.joined ? "joinedForReading" : "disconnected";
  public getClientId = (): string | undefined => this.clientId;
  public getQuorum = (): MockQuorumClients => this.quorum;
  public getAudience = (): MockAudience => this.audience;
  public submitSignal = (message: unknown): void => {
    this.onSubmit(message);
  };
}

function isShapedLikeX(raw: unknown): boolean {
  return typeof raw === "object" && raw !== null && typeof (raw as { x?: unknown }).x === "number";
}

export function run(input: Scenario): string {
  // The Swift peer reads the scenario as JSON; the oracle sees exactly the same data.
  const scenario = JSON.parse(JSON.stringify(input)) as Scenario;
  const clock = new FakeClock(startTime, scenario.randoms);
  const rows: Row[] = [];
  clock.onError = () => {
    rows.push({ t: clock.now(), error: "timer" });
  };
  clock.withInstalled(() => {
    new Simulation(scenario, clock, rows).execute();
  });
  return JSON.stringify(rows);
}

class Simulation {
  private readonly slots: Slot[] = [];
  private readonly members = new Map<string, ServiceMember>();
  private eventCounter = 0;
  private quorumCounter = 0;

  public constructor(
    private readonly scenario: Scenario,
    private readonly clock: FakeClock,
    private readonly rows: Row[],
  ) {
    for (let index = 0; index < scenario.slots; index += 1) {
      this.slots.push({
        index,
        attendeeId: `attendee-${index}`,
        runtime: undefined,
        presence: undefined,
        connectionCount: 0,
        workspaces: new Map(),
        subscribed: new Set(),
        armed: new Map(),
      });
    }
  }

  public execute(): void {
    for (const command of this.scenario.commands) {
      try {
        this.apply(command);
      } catch {
        this.rows.push({ t: this.clock.now(), slot: command.slot ?? null, error: command.kind });
      }
      if (command.kind !== "advance") {
        this.clock.advance(0);
      }
      this.rows.push(this.snapshot());
    }
  }

  private slotOf(command: Command): Slot {
    const slot = this.slots[command.slot ?? -1];
    if (slot === undefined) {
      throw new Error("bad slot");
    }
    return slot;
  }

  private presenceOf(slot: Slot): Presence {
    if (slot.presence === undefined) {
      throw new Error("slot not created");
    }
    return slot.presence;
  }

  private networkEntry(destination: number): { delay: number; drop: boolean } {
    const table = this.scenario.network;
    const entry = table[(this.eventCounter * 3 + destination * 11) % table.length];
    this.eventCounter += 1;
    if (entry === undefined) {
      throw new Error("empty network table");
    }
    return entry;
  }

  private row(slot: Slot, ev: string, payload: Row): void {
    this.rows.push({ t: this.clock.now(), slot: slot.index, ev, ...payload });
  }

  private apply(command: Command): void {
    switch (command.kind) {
      case "create":
        this.create(this.slotOf(command));
        break;
      case "connect":
        this.connect(this.slotOf(command), command.write === true, command.interactive !== false);
        break;
      case "disconnect":
        this.disconnect(this.slotOf(command));
        break;
      case "workspace":
        this.registerWorkspace(this.slotOf(command), command);
        break;
      case "arm": {
        const slot = this.slotOf(command);
        slot.armed.set(`${command.space as string}:${command.address as string}`, command);
        break;
      }
      case "set": {
        const manager = this.manager<LatestManager>(this.slotOf(command), command);
        manager.local = command.value;
        break;
      }
      case "mapSet": {
        const manager = this.manager<LatestMapManager>(this.slotOf(command), command);
        manager.local.set(command.mapKey as string, command.value);
        break;
      }
      case "mapDelete": {
        const manager = this.manager<LatestMapManager>(this.slotOf(command), command);
        const result = manager.local.delete(command.mapKey as string);
        this.row(this.slotOf(command), "mapDelete", { result });
        break;
      }
      case "mapClear": {
        const manager = this.manager<LatestMapManager>(this.slotOf(command), command);
        manager.local.clear();
        break;
      }
      case "notify":
        this.notify(this.slotOf(command), command);
        break;
      case "controls":
        this.controls(this.slotOf(command), command);
        break;
      case "inject":
        this.inject(this.slotOf(command), command);
        break;
      case "advance":
        this.clock.advance(command.ms as number);
        break;
      default:
        throw new Error(`unknown command ${command.kind}`);
    }
  }

  private create(slot: Slot): void {
    if (slot.presence !== undefined) {
      throw new Error("already created");
    }
    const runtime = new SlotRuntime((message) => {
      this.submit(slot, message);
    });
    slot.runtime = runtime;
    const presence = createPresenceManager(
      runtime as unknown as IEphemeralRuntime,
      slot.attendeeId as never,
    );
    slot.presence = presence;
    presence.attendees.events.on("attendeeConnected", (attendee) => {
      this.row(slot, "attendeeConnected", { attendee: attendee.attendeeId });
    });
    presence.attendees.events.on("attendeeDisconnected", (attendee) => {
      this.row(slot, "attendeeDisconnected", { attendee: attendee.attendeeId });
    });
    (presence as unknown as PresenceApi).events.on("workspaceActivated", (address, type) => {
      this.row(slot, "workspaceActivated", { address, type });
      const armed = slot.armed.get(`${type === "States" ? "states" : "notifications"}:${address}`);
      if (armed !== undefined) {
        slot.armed.delete(`${type === "States" ? "states" : "notifications"}:${address}`);
        this.registerWorkspace(slot, armed);
      }
    });
  }

  // Port of MockEphemeralRuntime.connect with the audience populated from the
  // service's current membership, which is what a real connection receives.
  private connect(slot: Slot, write: boolean, interactive: boolean): void {
    this.presenceOf(slot);
    const runtime = slot.runtime;
    if (runtime === undefined) {
      throw new Error("slot not created");
    }
    const connectionId = `c${slot.index}.${slot.connectionCount}`;
    slot.connectionCount += 1;
    const oldClientId = runtime.clientId;
    const member: ServiceMember = {
      connectionId,
      slot: slot.index,
      write,
      interactive,
      sequenceNumber: write ? 10 * this.quorumCounter : undefined,
    };
    if (write) {
      this.quorumCounter += 1;
    }
    const existing = [...this.members.values()];
    this.members.set(connectionId, member);
    const clientObject = clientDetails(write, interactive, slot.attendeeId);

    // Quorum views are reliable and immediate. The joiner's quorum is rebuilt from the service.
    for (const other of this.slots) {
      if (other.runtime !== undefined && other.index !== slot.index && write) {
        other.runtime.quorum.addMember(connectionId, {
          client: clientObject,
          sequenceNumber: member.sequenceNumber,
        } as never);
      }
    }
    for (const [staleId] of runtime.quorum.getMembers()) {
      runtime.quorum.removeMember(staleId);
    }
    if (write) {
      runtime.quorum.addMember(connectionId, { client: clientObject, sequenceNumber: member.sequenceNumber } as never);
    }
    for (const prior of existing) {
      if (prior.write) {
        runtime.quorum.addMember(prior.connectionId, {
          client: clientDetails(prior.write, prior.interactive, this.slots[prior.slot]?.attendeeId ?? ""),
          sequenceNumber: prior.sequenceNumber,
        } as never);
      }
    }

    const previousMembers = runtime.audience.getMembers();
    runtime.audience.setCurrentClientId(connectionId);
    runtime.clientId = connectionId;
    runtime.joined = true;
    for (const [memberId] of previousMembers) {
      runtime.audience.removeMember(memberId);
    }
    for (const prior of existing) {
      if (prior.connectionId !== oldClientId) {
        runtime.audience.addMember(
          prior.connectionId,
          clientDetails(prior.write, prior.interactive, this.slots[prior.slot]?.attendeeId ?? "") as never,
        );
      }
    }
    runtime.audience.addMember(connectionId, clientObject as never);

    for (const other of this.slots) {
      if (other.index === slot.index || other.runtime === undefined) {
        continue;
      }
      const target = other.runtime;
      const { delay } = this.networkEntry(other.index);
      this.clock.setTimeout(() => {
        if (target.joined) {
          target.audience.addMember(connectionId, clientObject as never);
        }
      }, delay);
    }
  }

  private disconnect(slot: Slot): void {
    const runtime = slot.runtime;
    if (runtime === undefined || !runtime.joined || runtime.clientId === undefined) {
      throw new Error("not connected");
    }
    const connectionId = runtime.clientId;
    this.members.delete(connectionId);
    runtime.joined = false;
    for (const listener of runtime.disconnectedListeners) {
      listener();
    }
    for (const other of this.slots) {
      if (other.index === slot.index || other.runtime === undefined) {
        continue;
      }
      const target = other.runtime;
      target.quorum.removeMember(connectionId);
      const { delay } = this.networkEntry(other.index);
      this.clock.setTimeout(() => {
        if (target.joined) {
          target.audience.removeMember(connectionId);
        }
      }, delay);
    }
  }

  // The driver-owned signal bus. `message` is what presence handed to submitSignal.
  private submit(sender: Slot, message: unknown): void {
    const json = JSON.stringify(message);
    const parsed = JSON.parse(json) as { targetClientId?: string };
    this.rows.push({ t: this.clock.now(), slot: sender.index, signal: parsed });
    const senderConnection = sender.runtime?.clientId;
    if (senderConnection === undefined) {
      throw new Error("sender has no connection");
    }
    for (const member of this.members.values()) {
      if (parsed.targetClientId !== undefined && member.connectionId !== parsed.targetClientId) {
        continue;
      }
      const destination = this.slots[member.slot];
      if (destination === undefined) {
        continue;
      }
      const entry = this.networkEntry(destination.index);
      if (entry.drop) {
        continue;
      }
      const destinationConnection = member.connectionId;
      this.clock.setTimeout(() => {
        const destinationRuntime = destination.runtime;
        if (destinationRuntime === undefined || !destinationRuntime.joined || destinationRuntime.clientId !== destinationConnection) {
          return;
        }
        const inbound = { ...(JSON.parse(json) as Record<string, unknown>), clientId: senderConnection };
        try {
          this.presenceOf(destination).processSignal([], inbound as never, senderConnection === destinationConnection);
        } catch {
          this.rows.push({ t: this.clock.now(), slot: destination.index, error: "processSignal" });
        }
      }, entry.delay);
    }
  }

  private inject(slot: Slot, command: Command): void {
    const message = { ...(command.message as Record<string, unknown>), clientId: command.from };
    this.presenceOf(slot).processSignal(
      command.addressChain as string[],
      message as never,
      command.local === true,
    );
  }

  private validatorFor(): (raw: unknown) => unknown {
    return (raw) => {
      this.rows.push({ t: this.clock.now(), validate: raw ?? null });
      return isShapedLikeX(raw) ? raw : undefined;
    };
  }

  private factoryFor(slot: Slot, entry: SchemaEntry): unknown {
    const settings = entry.latency === undefined ? undefined : { allowableUpdateLatencyMs: entry.latency };
    const validator = entry.validated === true ? this.validatorFor() : undefined;
    switch (entry.type) {
      case "latest":
        return StateFactory.latest({ local: entry.local as never, settings, validator } as never);
      case "latestMap":
        return StateFactory.latestMap({
          local: entry.local as never,
          settings,
          validator,
          keyValidator: entry.keyValidated === true ? (key: string) => !key.startsWith("bad") : undefined,
        } as never);
      case "notifications": {
        const subscriptions: Record<string, (attendee: Attendee, ...args: unknown[]) => void> = {};
        for (const name of entry.subscriptions ?? []) {
          subscriptions[name] = (attendee, ...args) => {
            this.row(slot, "notification", { name, attendee: attendee.attendeeId, args });
          };
        }
        return Notifications(subscriptions as never);
      }
    }
  }

  private registerWorkspace(slot: Slot, command: Command): void {
    const presence = this.presenceOf(slot) as unknown as PresenceApi;
    const space = command.space as string;
    const address = command.address as string;
    const schemaEntries = command.schema as SchemaEntry[];
    const schema: Record<string, unknown> = {};
    for (const entry of schemaEntries) {
      schema[entry.key] = this.factoryFor(slot, entry);
    }
    const settings =
      command.latency === undefined ? undefined : { allowableUpdateLatencyMs: command.latency as number };
    const workspace =
      space === "states"
        ? presence.states.getWorkspace(address, schema, settings)
        : presence.notifications.getWorkspace(address, schema);
    const id = `${space}:${address}`;
    const known = slot.workspaces.get(id) ?? { space, address, types: new Map<string, string>(), workspace };
    for (const entry of schemaEntries) {
      if (!known.types.has(entry.key)) {
        known.types.set(entry.key, entry.type);
      }
    }
    slot.workspaces.set(id, known);
    for (const entry of schemaEntries) {
      this.subscribe(slot, known, entry);
    }
  }

  private subscribe(
    slot: Slot,
    known: { space: string; address: string; workspace: Workspace },
    entry: SchemaEntry,
  ): void {
    const id = `${known.space}:${known.address}:${entry.key}`;
    if (slot.subscribed.has(id)) {
      return;
    }
    slot.subscribed.add(id);
    const base = { address: known.address, key: entry.key };
    const resolve = (value: unknown): unknown => (typeof value === "function" ? (value as Accessor)() : value);
    const manager = known.workspace.states[entry.key];
    switch (entry.type) {
      case "latest": {
        const latest = manager as LatestManager;
        latest.events.on("localUpdated", (payload) => {
          this.row(slot, "localUpdated", { ...base, value: payload.value });
        });
        latest.events.on("remoteUpdated", (payload) => {
          const metadata = payload.metadata as { revision: number; timestamp: number };
          this.row(slot, "remoteUpdated", {
            ...base,
            attendee: (payload.attendee as Attendee).attendeeId,
            value: resolve(payload.value),
            rev: metadata.revision,
            ts: metadata.timestamp,
          });
        });
        break;
      }
      case "latestMap": {
        const map = manager as LatestMapManager;
        map.events.on("localItemUpdated", (payload) => {
          this.row(slot, "localItemUpdated", { ...base, mapKey: payload.key, value: payload.value });
        });
        map.events.on("localItemRemoved", (payload) => {
          this.row(slot, "localItemRemoved", { ...base, mapKey: payload.key });
        });
        map.events.on("remoteItemUpdated", (payload) => {
          const metadata = payload.metadata as { revision: number; timestamp: number };
          this.row(slot, "remoteItemUpdated", {
            ...base,
            attendee: (payload.attendee as Attendee).attendeeId,
            mapKey: payload.key,
            value: resolve(payload.value),
            rev: metadata.revision,
            ts: metadata.timestamp,
          });
        });
        map.events.on("remoteItemRemoved", (payload) => {
          const metadata = payload.metadata as { revision: number; timestamp: number };
          this.row(slot, "remoteItemRemoved", {
            ...base,
            attendee: (payload.attendee as Attendee).attendeeId,
            mapKey: payload.key,
            rev: metadata.revision,
            ts: metadata.timestamp,
          });
        });
        map.events.on("remoteUpdated", (payload) => {
          const items = payload.items as Map<string, { value: unknown; metadata: { revision: number; timestamp: number } }>;
          this.row(slot, "remoteUpdated", {
            ...base,
            attendee: (payload.attendee as Attendee).attendeeId,
            items: [...items.entries()].map(([mapKey, item]) => ({
              mapKey,
              value: resolve(item.value),
              rev: item.metadata.revision,
              ts: item.metadata.timestamp,
            })),
          });
        });
        break;
      }
      case "notifications": {
        const notifications = manager as NotificationsManager;
        notifications.events.on("unattendedNotification", (name, sender, ...args) => {
          this.row(slot, "unattended", { ...base, name, attendee: (sender as Attendee).attendeeId, args });
        });
        break;
      }
    }
  }

  private manager<T>(slot: Slot, command: Command): T {
    const known = slot.workspaces.get(`${command.space as string}:${command.address as string}`);
    if (known === undefined) {
      throw new Error("workspace not registered");
    }
    return known.workspace.states[command.key as string] as T;
  }

  private notify(slot: Slot, command: Command): void {
    const manager = this.manager<NotificationsManager>(slot, command);
    const args = command.args as unknown[];
    if (command.target === undefined) {
      manager.emit.broadcast(command.name as string, ...args);
      return;
    }
    const target = this.presenceOf(slot).attendees.getAttendee(`attendee-${command.target as number}` as never);
    manager.emit.unicast(command.name as string, target, ...args);
  }

  private controls(slot: Slot, command: Command): void {
    const known = slot.workspaces.get(`${command.space as string}:${command.address as string}`);
    if (known === undefined) {
      throw new Error("workspace not registered");
    }
    const controls =
      command.key === undefined
        ? known.workspace.controls
        : (known.workspace.states[command.key as string] as LatestManager).controls;
    if (command.latency !== undefined || "latency" in command) {
      controls.allowableUpdateLatencyMs = command.latency as number | undefined;
    }
    if ("refresh" in command) {
      controls.forcedRefreshIntervalMs = command.refresh as number | undefined;
    }
  }

  // Everything an application can observe about every created slot.
  private snapshot(): Row {
    const slots: unknown[] = [];
    for (const slot of this.slots) {
      slots.push(slot.presence === undefined ? null : this.snapshotSlot(slot, slot.presence));
    }
    return { t: this.clock.now(), state: slots };
  }

  private attempt<T>(body: () => T): T | "error" {
    try {
      return body();
    } catch {
      return "error";
    }
  }

  private snapshotSlot(slot: Slot, presence: Presence): Row {
    const attendees = [...presence.attendees.getAttendees()];
    const resolve = (value: unknown): unknown => (typeof value === "function" ? (value as Accessor)() : value);
    const workspaces: Row[] = [];
    for (const known of slot.workspaces.values()) {
      const managers: Row[] = [];
      for (const [key, type] of known.types) {
        const manager = known.workspace.states[key];
        managers.push({ key, ...this.snapshotManager(type, manager, attendees, resolve) });
      }
      workspaces.push({ space: known.space, address: known.address, managers });
    }
    return {
      myself: presence.attendees.getMyself().attendeeId,
      attendees: attendees.map((attendee) => ({
        id: attendee.attendeeId,
        status: attendee.getConnectionStatus(),
        connection: this.attempt(() => attendee.getConnectionId()),
      })),
      workspaces,
    };
  }

  private snapshotManager(
    type: string,
    manager: unknown,
    attendees: Attendee[],
    resolve: (value: unknown) => unknown,
  ): Row {
    if (type === "latest") {
      const latest = manager as LatestManager;
      return {
        local: latest.local,
        remotes: this.attempt(() =>
          [...latest.getRemotes()].map((remote) => ({
            attendee: remote.attendee.attendeeId,
            value: resolve(remote.value),
            rev: remote.metadata.revision,
            ts: remote.metadata.timestamp,
          })),
        ),
        stateAttendees: this.attempt(() => latest.getStateAttendees().map((a) => a.attendeeId)),
        byAttendee: attendees.map((attendee) =>
          this.attempt(() => {
            const remote = latest.getRemote(attendee);
            return { value: resolve(remote.value), rev: remote.metadata.revision, ts: remote.metadata.timestamp };
          }),
        ),
      };
    }
    if (type === "latestMap") {
      const map = manager as LatestMapManager;
      const itemRows = (items: Map<string, { value: unknown; metadata: { revision: number; timestamp: number } }>): Row[] =>
        [...items.entries()].map(([mapKey, item]) => ({
          mapKey,
          value: resolve(item.value),
          rev: item.metadata.revision,
          ts: item.metadata.timestamp,
        }));
      return {
        size: map.local.size,
        local: [...map.local.keys()].map((mapKey) => [mapKey, map.local.get(mapKey)]),
        remotes: this.attempt(() =>
          [...map.getRemotes()].map((remote) => ({ attendee: remote.attendee.attendeeId, items: itemRows(remote.items) })),
        ),
        stateAttendees: this.attempt(() => map.getStateAttendees().map((a) => a.attendeeId)),
        byAttendee: attendees.map((attendee) => this.attempt(() => itemRows(map.getRemote(attendee)))),
      };
    }
    return {};
  }
}
