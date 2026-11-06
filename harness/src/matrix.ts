import { z } from "zod";
import type { ISharedMatrix } from "@fluidframework/matrix/internal";
import { MockHandle } from "@fluidframework/test-runtime-utils/internal";
import type { Adapter } from "./dds.js";
import { wireReplacer } from "./dds.js";
import type { Edit } from "./protocol.js";
import type { Random } from "./random.js";

const canonical = (value: unknown): unknown => value === undefined
  ? { $fluid: "undefined" }
  : JSON.parse(JSON.stringify(value, wireReplacer));

export function matrixAdapter(c: ISharedMatrix<unknown>): Adapter {
  const events: unknown[] = [];
  c.openMatrix({
    rowsChanged: (start, removed, inserted) => events.push(["rowsChanged", start, removed, inserted]),
    colsChanged: (start, removed, inserted) => events.push(["colsChanged", start, removed, inserted]),
    cellsChanged: (row, col, rows, cols) => events.push(["cellsChanged", row, col, rows, cols]),
  });
  c.on("conflict", (row, col, current, ignored) => events.push(["conflict", row, col, canonical(current), canonical(ignored)]));
  return {
    channel: c,
    events,
    edit(e) {
      switch (e.kind) {
        case "insertRows":
          c.insertRows(e.start, e.count);
          break;
        case "removeRows":
          c.removeRows(e.start, e.count);
          break;
        case "insertCols":
          c.insertCols(e.start, e.count);
          break;
        case "removeCols":
          c.removeCols(e.start, e.count);
          break;
        case "switchSetCellPolicy":
          c.switchSetCellPolicy();
          break;
        case "setCell":
          c.setCell(e.row, e.col, e.valueKind === "undefined" ? undefined : e.valueKind === "handle" ? new MockHandle(null, "/handles/a", "/handles/a") : e.value);
          break;
        default: throw new Error(`Invalid matrix edit ${e.kind}`);
      }
    },
    state: () => ({ rowCount: c.rowCount, colCount: c.colCount, cells: Array.from({ length: c.rowCount }, (_, row) => Array.from({ length: c.colCount }, (_, col) => canonical(c.getCell(row, col)))) }),
    queries: () => ({ rowCount: c.rowCount, colCount: c.colCount, fww: c.isSetCellConflictResolutionPolicyFWW() }),
  };
}
const queriesSchema = z.object({ rowCount: z.number().int().nonnegative(), colCount: z.number().int().nonnegative(), fww: z.boolean() });

/** matrix/src/test/fuzz.ts: default weights, eligibility and max dimension change 3.
 * Undefined extends the upstream value pool to cover the documented clearing operation.
 * Upstream's model has no undo/redo operations.
 */
export function generateMatrix(r: Random, queries: unknown): Edit {
  const q = queriesSchema.parse(queries);
  const choices: [string, number][] = [["insertRows", 10], ["insertCols", 10]];
  if (q.rowCount > 0) choices.push(["removeRows", 10]);
  if (q.colCount > 0) choices.push(["removeCols", 10]);
  if (q.rowCount > 0 && q.colCount > 0) choices.push(["setCell", 200]);
  if (!q.fww) choices.push(["switchSetCellPolicy", 1]);
  let pick = r.int(choices.reduce((sum, [, weight]) => sum + weight, 0));
  for (const [kind, weight] of choices) {
    if (pick >= weight) {
      pick -= weight;
      continue;
    }
    if (kind === "switchSetCellPolicy") return { kind };
    if (kind === "setCell") {
      const valueKind = r.pick(["plain", "plain", "handle", "undefined"] as const);
      const value = r.int(2) === 0 ? r.int(50) + 1 : Array.from({ length: 1 + r.int(2) }, () => String.fromCharCode(97 + r.int(26))).join("");
      return { kind, row: r.int(q.rowCount), col: r.int(q.colCount), value, ...(valueKind === "plain" ? {} : { valueKind }) };
    }
    const length = kind.endsWith("Rows") ? q.rowCount : q.colCount;
    const insert = kind.startsWith("insert");
    const start = r.int(length + (insert ? 1 : 0));
    const count = 1 + r.int(insert ? 3 : Math.min(3, length - start));
    switch (kind) {
      case "insertRows":
      case "insertCols":
      case "removeRows":
      case "removeCols":
        return { kind, start, count };
      default: throw new Error("Unreachable matrix operation");
    }
  }
  throw new Error("No eligible matrix operation");
}
