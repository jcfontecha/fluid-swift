import { z } from "zod";
import type { ISharedString, SequenceInterval } from "@fluidframework/sequence/internal";
import { ReferenceType } from "@fluidframework/merge-tree/internal";
import type { Adapter } from "./dds.js";
import type { Edit } from "./protocol.js";
import type { Random } from "./random.js";

const compare = (a: string, b: string): number => a < b ? -1 : a > b ? 1 : 0;
const units = (text: string): number[] => Array.from({ length: text.length }, (_, i) => text.charCodeAt(i));
function properties(value: unknown): unknown {
  if (value === undefined) return {};
  const parsed = z.record(z.string(), z.json()).parse(value);
  return Object.fromEntries(Object.entries(parsed).sort(([a], [b]) => compare(a, b)));
}

export function sharedStringAdapter(c: ISharedString): Adapter {
  const events: unknown[] = [];
  const interval = (i: SequenceInterval) => ({
    id: i.getIntervalId(),
    start: c.localReferencePositionToPosition(i.start),
    end: c.localReferencePositionToPosition(i.end),
    properties: properties(i.properties),
  });
  const subscribe = (label: string): void => {
    const collection = c.getIntervalCollection(label);
    collection.on("addInterval", (i, local) => events.push(["addInterval", label, interval(i), local]));
    collection.on("deleteInterval", (i, local) => events.push(["deleteInterval", label, interval(i), local]));
    collection.on("changeInterval", (i, previous, local, _op, slide) => events.push(["changeInterval", label, interval(i), interval(previous), local, slide]));
    collection.on("propertyChanged", (i, delta, local) => events.push(["propertyChanged", label, interval(i), properties(delta), local]));
  };
  for (const label of c.getIntervalCollectionLabels()) subscribe(label);
  c.on("createIntervalCollection", (label) => {
    events.push(["createIntervalCollection", label]);
    subscribe(label);
  });
  c.on("sequenceDelta", (event) => events.push([
    "sequenceDelta", event.deltaOperation, event.isLocal,
    event.ranges.map((range) => ({
      position: range.position,
      segment: range.segment.toJSONObject(),
      propertyDeltas: range.propertyDeltas,
    })),
  ]));
  c.on("maintenance", (event) => events.push([
    "maintenance", event.deltaOperation, event.opArgs?.sequencedMessage === undefined,
    event.ranges.map((range) => ({
      position: range.position,
      segment: range.segment.toJSONObject(),
      propertyDeltas: range.propertyDeltas,
    })),
  ]));
  const collections = () => [...c.getIntervalCollectionLabels()].sort(compare).map((label) => ({
    label,
    intervals: [...c.getIntervalCollection(label)].map(interval).sort((a, b) => compare(a.id ?? "", b.id ?? "")),
  }));
  return {
    channel: c,
    events,
    edit(e) {
      switch (e.kind) {
        case "insertText":
          c.insertText(e.position, e.text, e.props);
          break;
        case "insertMarker":
          c.insertMarker(e.position, ReferenceType.Tile, e.props);
          break;
        case "removeRange":
          c.removeRange(e.start, e.end);
          break;
        case "annotateRange":
          c.annotateRange(e.start, e.end, e.props);
          break;
        case "addInterval": {
          // The concrete upstream overload accepts id; the public interface omits it.
          const options = { id: e.id, start: e.start, end: e.end, props: e.props };
          c.getIntervalCollection(e.collection).add(options);
          break;
        }
        case "changeInterval":
          c.getIntervalCollection(e.collection).change(e.id, { start: e.start, end: e.end, props: e.props });
          break;
        case "deleteInterval":
          c.getIntervalCollection(e.collection).removeIntervalById(e.id);
          break;
        default:
          throw new Error(`Invalid SharedString edit ${e.kind}`);
      }
    },
    state: () => ({
      text: units(c.getText()),
      positions: Array.from({ length: c.getLength() }, (_, position) => {
        const { segment } = c.getContainingSegment(position);
        return { properties: properties(c.getPropertiesAtPosition(position)), marker: segment?.type === "Marker" ? segment.toJSONObject() : null };
      }),
      collections: collections(),
    }),
    queries: () => ({ length: c.getLength(), collections: collections() }),
  };
}
const querySchema = z.object({
  length: z.number().int().nonnegative(),
  collections: z.array(z.object({ label: z.string(), intervals: z.array(z.object({ id: z.string() })) })),
});

function intervalEndpoints(r: Random, start: number, end: number) {
  const choice = r.int(10);
  if (choice === 0) return { start: "start", end: "end" } as const;
  if (choice < 5) return { start: { pos: start, side: r.pick([0, 1] as const) }, end: { pos: end, side: r.pick([0, 1] as const) } };
  return { start, end };
}

/** sequence/src/test/fuzz/fuzzUtils.ts: eligible weighted operations, with obliterate disabled. */
export function generateSharedString(r: Random, queries: unknown): Edit {
  const q = querySchema.parse(queries);
  const intervals = q.collections.flatMap((c) => c.intervals.map((i) => ({ collection: c.label, id: i.id })));
  const choices = ["insertText", "insertText", "insertMarker"];
  if (q.length > 0) choices.push("removeRange", "annotateRange", "addInterval", "addInterval");
  if (intervals.length > 0) choices.push("deleteInterval", "deleteInterval");
  if (intervals.length > 0 && q.length > 0) choices.push("changeInterval", "changeInterval");
  const kind = r.pick(choices);
  const start = r.int(Math.max(q.length, 1));
  const end = start + r.int(Math.max(q.length - start, 1));
  const props = { [r.pick(["prop1", "prop2", "prop3"])]: r.int(4) === 0 ? null : r.int(100) };
  switch (kind) {
    case "insertText": return { kind, position: r.int(q.length + 1), text: r.pick(["abc", "x", "😀", "\ud800", "\udfff", "é"]), props };
    case "insertMarker": return { kind, position: r.int(q.length + 1), props: { referenceTileLabels: ["paragraph"], ...props } };
    case "removeRange": return { kind, start, end: end + 1 };
    case "annotateRange": return { kind, start, end: end + 1, props };
    case "addInterval": return { kind, collection: r.pick(["comments", "notes", "0"]), id: Array.from({ length: 4 }, () => r.int(0x100000000).toString(16)).join("-"), ...intervalEndpoints(r, start, end), props };
    case "deleteInterval": return { kind, ...r.pick(intervals) };
    case "changeInterval": return r.int(2) === 0
      ? { kind, ...r.pick(intervals), ...intervalEndpoints(r, start, end), props }
      : { kind, ...r.pick(intervals), props };
    default: throw new Error("Unreachable SharedString operation");
  }
}
