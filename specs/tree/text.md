# Text — Fluid Framework 3.11.0

## 1. Role

PlainText and FormattedText are domain schemas over SharedTree arrays and object nodes, not the legacy SharedString/merge-tree DDS. Sequence CRDT behavior comes from the ordinary array field. Optimized string storage/field-batch encoding must preserve the same atoms and schema identities. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:63-76` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:339-345`

## 2. Surface used by other packages

`PlainText.Tree` with fromString, insertAt/removeRange/moveRangeToIndex, characters/charactersCopy/fullString/characterCount, onCharactersChanged and insertion anchors; `FormattedText` schema factories with/without ranges, StringTextAtom, formatting APIs, onContentChanged, getUniformRun/getString; `codePointCount` and `utf16LengthForCodePoints`. TS erased schema types and generic format/extra-atom inference can become Swift generated types; persisted field names and atom coordinates cannot change. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:159-242` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:411-723` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/codePointUtils.ts:33-92`

## 3. Wire and persisted formats

No independent text op envelope. PlainText schema scope `com.fluidframework.text`, object `Text` has required public `content` stored as `""`, pointing to `StringArray` whose sequence of strings also uses `""`. Example logical typed tree for `"a😀"` is Text {empty-key: StringArray {empty-key: [string("a"),string("😀")]}}; **not** one string leaf holding the whole text. Node IDs are `com.fluidframework.text.Text` and `com.fluidframework.text.StringArray`. Actual summary bytes use forest/field-batch codecs in [chunked-forest.md](chunked-forest.md), including its experimental text shapes. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:63-76` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:245-271`

Formatted types use customized scope `com.fluidframework.text.formatted<user-scope>`; Text has required content under `""`; StringArray elements are StringAtom with required content under `""` and required `format` under `"format"`; content permits static `com.fluidframework.text.formatted.StringTextAtom` and extra supplied atom types. StringTextAtom has required string content under `""`. With-ranges variant additionally has optional public `rangeStorage`, stored `"ranges"`, a map ExtrinsicRanges→ExtrinsicRange objects `{data,start:number,end:number}`. These fields and wrapper nodes are persisted; flattening them into an attributed string is not wire compatible. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:77-129` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:339-345` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:758-760` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:900-920`

Text event delta (LOCAL API, not wire ops) is an ordered array of `{type:"retain",count:number,formattingChanged?:boolean}`, `{type:"insert",text:string}`, `{type:"remove",count:number}`. Plain events omit formattingChanged; formatted content events retain it as true/false. Example inserting 😀 after `a`: `[{"type":"retain","count":1},{"type":"insert","text":"😀"}]` (no trailing retain if no remaining atoms). Count is atoms, while `text` may occupy more UTF-16 units. An unavailable delta is undefined, not `[]`. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:283-328` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:388-452`

## 4. Behavior

### Coordinates and construction

Default segmentation uses JavaScript string iteration: valid surrogate pairs form one code point; unmatched surrogates remain one atom each. Joined emoji and combining sequences remain MULTIPLE atoms. `characterCount` returns underlying array length; fullString joins contents with empty separator; constructors/imports can legally produce longer strings per atom, so counting code points in fullString cannot reconstruct general atom boundaries. StringTextAtom.fromCharacter requires exactly one iterated code point; direct schema construction allows larger content. Swift String.Character uses grapheme clusters and is wrong here. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:175-242` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:105-134`

`PlainText.fromString` explicitly materializes the character iterator as an array, because raw strings are rejected as ambiguous array-constructor input. insertAt spreads the iterator into an array insertion; removeRange and moveRange delegate unchanged. Move destination is a pre-move gap. `utf16LengthForCodePoints(value,start,count)` validates start in [0,UTF16 length], rejects negative count, advances 2 units for codePointAt>0xFFFF else 1, throws on exhaustion instead of truncating. Starting on the low half of a surrogate pair consumes that half as one unit, exactly JS behavior. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:159-173` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:227-245` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/codePointUtils.ts:68-92`

### Event translation

For each array delta, readPosition starts 0. Retain appends retain (formatted flag only if subtreeChanged property exists), advances readPosition. Insert reads op.count CURRENT atoms starting readPosition, advances once per atom, concatenates into text; missing atom aborts with callback(undefined). Remove appends remove/count and does not advance readPosition (it addresses the already-edited array). Callback receives all translated ops once. No synthesized retry edit. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:283-328`

### Complete text-event translation

Literal oracle procedure (comments removed), `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:283-324`:

```typescript
export function processCharactersChangedDelta(
	delta: readonly (ArrayNodeDeltaOp | ArrayNodeTreeChangedDeltaOp)[] | undefined,
	getCharacter: (index: number) => string | undefined,
	callback: (ops: readonly PlainText.TextOp[] | undefined) => void,
): void {
	if (delta === undefined) {
		callback(undefined);
		return;
	}
	let readPosition = 0;
	const ops: PlainText.TextOp[] = [];
	for (const op of delta) {
		if (op.type === "retain") {
			ops.push(
				"subtreeChanged" in op
					? { type: "retain", count: op.count, formattingChanged: op.subtreeChanged === true }
					: { type: "retain", count: op.count },
			);
			readPosition += op.count;
		} else if (op.type === "insert") {
			const characters: string[] = [];
			for (let i = 0; i < op.count; i++) {
				const character = getCharacter(readPosition);
				if (character === undefined) {
					callback(undefined);
					return;
				}
				characters.push(character);
				readPosition++;
			}
			ops.push({ type: "insert", text: characters.join("") });
		} else {
			ops.push({ type: "remove", count: op.count });
		}
	}
	callback(ops);
}
```

### Formatted edits

Create default format once from defaultFormatInsertable. Missing format parameter chooses this default; explicit null is valid and must NOT take the default. Clone format for EACH inserted atom so formatting never aliases mutable nodes. Inserting a string segments code points; inserting extra atoms retains their type/content. StringArray is ordinary tree sequence, so removal and move preserve content/format wrapper identities. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:310-336` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:411-464`

formatRange is a partial property update: reject a leaf input; gather map-like iterator pairs or Object.entries; cache operation by existing format schema. Existing leaf or array formats reject partial editing; map/record update entry values by independently cloned inputs; object verifies every key is known before assigning cloned values. Unknown optional keys are not accepted as ad hoc JS properties. reformat replaces every atom's entire format with a clone of the requested/default node. Both validate start (default 0), clamp end to array length, validate ordering, and apply atom edits within a tree transaction. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:536-679`

onCharactersChanged listens to nodeChanged (shallow sequence edits); onContentChanged listens to treeChanged (also format/content edits) and translates subtreeChanged to formattingChanged. An object property edit should not look like deletion/reinsertion of text. getUniformRun stops when neighboring format fields differ under cursor comparison, and getString concatenates atom contents over [start,end). Both return snapshots, not live mutable Foundation strings. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:691-723` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:835-895`

With-ranges exposes an ExtrinsicRangeTracker and uses #editContent to track ranges around content edits. Plain variant does not create range storage accidentally. The following is the complete range-enabled edit wrapper; it specifies transaction and location update order without requiring the Swift porter to infer it from the public API. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:394-409`

### Range-aware content edit procedure

Literal oracle procedure, `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:386-392`:

```typescript
			#editContent(edit: (content: StringArray) => void): void {
				if (includeRanges) {
					this.#getRangeTracker().transactOnContent(edit);
				} else {
					edit(this.content);
				}
			}
```

## 5. Invariants and asserts

Formatting range iteration assumes validated atom exists (0xd08). Format schemas must match record/map/object categories (0xd72–0xd76); leaf/array partial formats throw UsageError. Out-of-range text offsets must reject rather than silently drift. Optional expensive optimized-vs-reference checks compare charactersCopy and fullString against array iteration/join. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:571-611` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:667-678` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:183-210`

## 6. JS-semantics hazards

Three distinct coordinate spaces: UTF-16 units in string utilities, Unicode code points in default segmentation, stored atoms in array indices. Never use Foundation String.count. Preserve lone surrogates via FluidJS. Explicit null format is not default; clone format independently per atom. Event deltas describe current array state; reading inserted content from pre-edit snapshots yields wrong characters. `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomainFormatted.ts:318-326` `reference/fluidframework-3.11.0/packages/dds/tree/src/text/textDomain.ts:283-328`

## 7. Test assets to reuse

`src/test/text/codePointUtils.spec.ts`, `textDomain.spec.ts`, `textDomainFormatted.spec.ts`, `textDomainFormattedRanges.spec.ts`, `textDomainFormattedRanges.example.spec.ts`; text/chunk golden tests and string-storage utility tests. Include a😀b (3 default atoms, 4 UTF-16 units), combining marks, ZWJ sequences, lone surrogates, user-supplied multicode-point atom, deep-only format delta, concurrent format vs move and range edge insertions. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/text/codePointUtils.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/text/textDomainFormattedRanges.spec.ts:1`

## 8. Open questions

None for text semantics. Swift attributed-string interop is a projection and must retain an explicit atom↔UTF-16 mapping.

