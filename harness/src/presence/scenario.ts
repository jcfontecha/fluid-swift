// Scenario wire format shared by the TS oracle, the generator and (as JSON) the Swift peer.
// See "Presence (H9)" in harness/PROTOCOL.md.

export interface NetworkEntry {
  // Milliseconds between a signal being submitted and delivered to one destination.
  delay: number;
  drop: boolean;
}

export type ManagerType = "latest" | "latestMap" | "notifications";

export interface SchemaEntry {
  key: string;
  type: ManagerType;
  // latest: initial local value (object or null). latestMap: initial items by key.
  local?: unknown;
  // Manager-level allowableUpdateLatencyMs.
  latency?: number;
  // latest / latestMap: use a validator that logs each call and accepts only
  // values shaped like { x: number } (latestMap: item values).
  validated?: boolean;
  // latestMap: reject keys that start with "bad".
  keyValidated?: boolean;
  // notifications: names that get a named listener (others are unattended).
  subscriptions?: string[];
}

export interface Command {
  kind: string;
  slot?: number;
  [field: string]: unknown;
}

export interface Scenario {
  seed: number;
  slots: number;
  // Indexed by (signalNumber * 3 + destinationSlot * 11) % network.length.
  network: NetworkEntry[];
  // Math.random sequence, cycled.
  randoms: number[];
  commands: Command[];
}

export const startTime = 1_000_000;
