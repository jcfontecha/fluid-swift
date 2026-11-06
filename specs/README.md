# Specs

One file per TS package, `specs/<package-dir-name>.md`, describing `client_v3.11.0` (the oracle
version) as checked out in `reference/fluidframework-3.11.0`. Specs are reading aids for porters:
the TS code and the differential harness stay the source of truth. Every claim cites
`path/from/repo/root.ts:line`.

## Quality bar

- **No deferrals.** Never write "inspect", "see X for details", "verify in source", or an elided
  citation. If a porter would have to open the file to learn a field name, an order, or a branch
  condition, the spec is not finished.
- Every wire or persisted format is given literally: field names, types, optionality, emission
  order, and a concrete example derived from the code path that produces it.
- Every state machine is given as states and transitions, with each transition's exact predicate
  and side effects in TS execution order, and the events emitted, in order.
- Every citation is a real `path:line` or `path:start-end`. Length follows the package's real
  complexity, with no filler.

## Sections

Every spec uses these sections, in order (write "None." rather than dropping one):

1. **Role** — what the package does and which layers call it, in a few sentences.
2. **Surface used by other packages** — the types/functions/classes other client packages import,
   with citations. Skip test-only and deprecated-and-unused exports.
3. **Wire and persisted formats** — every JSON/binary shape it sends, receives, or writes into a
   summary: exact field names, optionality, emission order, version/feature gates, and which
   format versions a 3.11.0 client must still read.
4. **Behavior** — the normative algorithms and state machines, step by step, in the order TS
   executes them, including event emission order and what happens on reconnect/error.
5. **Invariants and asserts** — conditions TS asserts (with assert short codes), and what fails.
6. **JS-semantics hazards** — places where a faithful Swift port could silently diverge: number
   precision and formatting, UTF-16 lengths/offsets, `Map`/object key order, `undefined` vs
   missing vs `null`, `JSON.stringify` dropping fields, sort stability and comparators, `Date`,
   reliance on microtask/event-loop ordering.
7. **Test assets to reuse** — unit tests, fuzz models, snapshot/golden files worth porting or
   running against the Swift port.
8. **Open questions** — anything you could not resolve from the code.
