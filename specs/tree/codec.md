# Codec — Fluid Framework 3.11.0

## 1. Role

Codec infrastructure separates format registration, write-format selection, incoming read dispatch, JSON schema validation, and parent-selected dependent codecs. It does not serialize every tree value into a universal envelope. Every concrete format owns its literal payload, and the parent's version fixes unversioned child formats. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:301-382` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:331-450`

## 2. Surface used by other packages

`IJsonCodec`, `IEncoder`, `IDecoder`, `ICodecFamily`, `makeCodecFamily`, `FormatVersion`, `CodecWriteOptions`, validator adapters, `withSchemaValidation`, `throwDecodeError`, dependent version lookups, `VersionDispatchingCodecBuilder`, discontinued codecs, `DiscriminatedUnionDispatcher`, `FluidClientVersion`, `CodecTree`. TS generic context parameters, schema inference, erased brands and static builder conditional types are scaffolding; Swift needs the encode/decode contracts, not their TS spelling. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:18-50` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:231-382` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:533-574`

## 3. Wire and persisted formats

`FormatVersion = number | string | undefined`; keys must distinguish 3 from "3" and absent from null. Stable formats are numeric, experimental formats may be strings; absent version is accepted only if explicitly registered. The generic version check requires an object with `version` matching registered values; it does NOT insert a version property itself. Child codecs such as SharedTreeChange are arrays and resolve through their parent's format rather than this object dispatcher. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:337` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:45-100`

A complete real versioned payload is the empty EditManager v3 summary `{"trunk":[],"branches":[],"version":3}`. Numeric 3 dispatches the registered numeric codec; changing it to string "3" does not. A complete empty SharedTreeChange payload is `[]`, with no version property, decoded using the parent-selected codec. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/shared-tree/summary-load-snapshots/singleTree-Compressed-v2_0-1.json:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeCodecs.ts:178-224`

Discriminated unions have exactly one own key; example `{"data":[]}` has discriminant `data` and value `[]` (only a union-shape illustration, not a valid modular changeset). `{}` and `{"data":{},"schema":{}}` fail 0x733 even with a no-op validator. `unionOptions` sets `additionalProperties:false,minProperties:1,maxProperties:1`; dispatcher uses Reflect.ownKeys, not enumerable-only Object.keys. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/discriminatedUnions.ts:21-25` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/discriminatedUnions.ts:124-132`

`CodecTree` is diagnostic `{name:string,version:FormatVersion,children?:CodecTree[]}`. jsonable conversion preserves a defined number/string version, replaces undefined version with the literal STRING "null", and recursively converts children (undefined children disappear on JSON.stringify). This is NOT the write registry, nor a payload version header. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:629-641`

### Effective collaboration floor and write formats

The runtime setting is called `oldestSupportedClient`; SharedTree consumes its propagated `args.minVersionForCollab`. Exact tree-level precedence is explicit `options.minVersionForCollab ?? args.minVersionForCollab ?? "2.0.0"`. A configured tree override therefore wins over container setting. SharedTree rejects floors below 2.0. Choosing a high floor is not negotiating with connected clients; it changes what can be written and subsequently read by older clients. `reference/fluidframework-3.11.0/packages/dds/tree/src/treeFactory.ts:58-78` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:229-231` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/sandboxing.ts:15-24`

This cumulative table gives automatic stable writing; each row supersedes only changed columns. "baseline" means accepted floors before 2.43. Layout numbers are NOT payload versions.

| floor | Message | EditManager | SharedTree / Modular | Sequence | Optional | Schema | DetachedIndex | FieldBatch | Forest payload / layout |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| baseline | 3 | 3 | 3 | 2 | 2 | 1 | 1 | 1 | 1 / 2 |
| 2.43 | 4 | 4 | 4 | 3 | 2 | 2 | 1 | 1 | 1 / 2 |
| 2.52 | 4 | 4 | 4 | 3 | 2 | 2 | 2 | 1 | 1 / 2 |
| 2.73 | 4 | 4 | 4 | 3 | 2 | 2 | 2 | 2 | 1 / 2 |
| 2.74 | 4 | 4 | 4 | 3 | 2 | 2 | 2 | 2 | 2 / 3 |
| 2.80 | 6 | 6 | 5 | 3 | 2 | 2 | 2 | 2 | 2 / 3 |
| 2.117 | 7 | 7 | 5 | 3 | 2 | 2 | 2 | 2 | 2 / 3 |

Registry sources: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecs.ts:86-166` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecs.ts:71-153` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:538-579` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:107-168` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:100-119` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecs.ts:22-41` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:319-351` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:76-89` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryTypes.ts:21-28`

3.11 readers: message/edit-manager stable 3,4,6,7 and explicitly experimental shared-branches format; registered discontinued missing/1/2/5 paths throw, not successful legacy reads. SharedTreeChange/modular 3,4,5; sequence 1/2/3; optional 1/2; schema 1/2; detached-index 1/2; field-batch 1/2 plus experimental `text`; forest payload 1/2. Field algebras/format declarations and exact snapshots belong to their matching specs. Experimental shared-branches maps SharedTree/modular to 4, NOT newest 5. No-change constraints therefore cannot be assumed merely because the outer experimental format sounds newer. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecs.ts:86-166` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecs.ts:71-153` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:538-579` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:319-351`

## 4. Behavior

### Registry and dispatch state machine

Unbuilt→normalized: reject duplicate format versions (debug invariant); string experimental versions must not advertise a collaboration floor; stable floors unique; baseline entry required. Codec definitions can be factories evaluated with build options. Build evaluates registry, builds decoder map, chooses writer once, returns encode bound to that writer plus dispatching decode. Incoming version selects independently of chosen writer; unknown incoming version throws UsageError including supported versions. No retry with a different codec. A registered discontinued codec is selected normally and throws its discontinued-format UsageError on encode/decode. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:355-486` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:127-152`

Writer selection: if overrides map HAS codec name, locate exact format; absent registration throws even with unsafe flag. Unless `allowPossiblyIncompatibleWriteVersionOverrides === true`, reject undefined selected collaboration floor, then reject selected floor newer than effective floor. Otherwise accept override. Without override filter entries with defined floor and choose newest compatible stable config by semantic version, not numeric format maximum or lexicographic version. A present map entry with undefined value is distinct from no entry. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:580-632`

### Exact write-selection branches

Literal oracle procedure (comments removed), `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:583-633`:

```typescript
function getWriteVersion<T extends CodecVersionBase>(
	name: CodecName,
	options: CodecWriteOptions,
	versions: readonly T[],
): T {
	if (options.writeVersionOverrides?.has(name) === true) {
		const selectedFormatVersion = options.writeVersionOverrides.get(name);
		const selected = versions.find((codec) => codec.formatVersion === selectedFormatVersion);
		if (selected === undefined) {
			throw new UsageError(
				`Codec "${name}" does not support requested format version ${JSON.stringify(selectedFormatVersion)}. Supported versions are: ${versionList(versions)}.`,
			);
		} else if (options.allowPossiblyIncompatibleWriteVersionOverrides !== true) {
			const selectedMinVersionForCollab = selected.minVersionForCollab;
			if (selectedMinVersionForCollab === undefined) {
				throw new UsageError(
					`Codec "${name}" does not support requested format version ${JSON.stringify(selectedFormatVersion)} because it has minVersionForCollab undefined. Use "allowPossiblyIncompatibleWriteVersionOverrides" to suppress this error if appropriate.`,
				);
			} else if (gt(selectedMinVersionForCollab, options.minVersionForCollab)) {
				throw new UsageError(
					`Codec "${name}" does not support requested format version ${JSON.stringify(selectedFormatVersion)} because it is only compatible back to client version ${selectedMinVersionForCollab} and the requested oldest compatible client was ${options.minVersionForCollab}. Use "allowPossiblyIncompatibleWriteVersionOverrides" to suppress this error if appropriate.`,
				);
			}
		}
		return selected;
	}
	return getWriteVersionNoOverrides(versions, options.minVersionForCollab);
}
function getWriteVersionNoOverrides<T extends CodecVersionBase>(
	versions: readonly T[],
	minVersionForCollab: OldestSupportedClientVersion,
): T {
	const stableVersions: [MinimumMinorSemanticVersion | OldestSupportedClientVersion, T][] = [];
	for (const version of versions) {
		if (version.minVersionForCollab !== undefined) {
			stableVersions.push([version.minVersionForCollab, version]);
		}
	}
	const result: T = getConfigForMinVersionForCollabIterable(
		minVersionForCollab,
		stableVersions,
	);
	return result;
}
```

### Validation and error propagation

`makeCodecFamily` rejects duplicate registry keys (0xabf), resolves unsupported versions with assert 0x5e6, and enumerates formats in insertion order. `withSchemaValidation` returns inner unchanged if no validator supplied; otherwise compiles once, validates AFTER encode (0xac0 on invalid encoder output), BEFORE decode, then forwards optional onError to inner decoder. `throwDecodeError` calls provided error handler or throws default assertion; it does not swallow malformed input. `FormatValidatorNoOp` is the default tree policy but sandbox always selects interpreted validation. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:61-68` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:399-449` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:469-513` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:755` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:298-313`

No version migration is applied in place: decode constructs the current in-memory form; subsequent encode uses selected writer. `getCodecTree(clientVersion)` deliberately uses no overrides, so it cannot prove an overridden writer's actual output. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:507-514`

## 5. Invariants and asserts

0x88b checks encoded version belongs to codec's supported set. 0xabf duplicate family codec; 0x5e6 unsupported family resolution; 0xac0 malformed encoder output; 0x733 union must have exactly one own member; 0xac2 unregistered union key. Stable floor uniqueness and string-format instability are debugAssert, not unconditional runtime input validation. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:65-69` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:380-414` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/discriminatedUnions.ts:124-132`

## 6. JS-semantics hazards

Represent format keys as tagged number/string/missing, not String(describing:). Use semantic version comparison (`2.117` > `2.80`), not string comparison. Property omission and JS property order belong to FluidJS. Codec validators being optional does not license Swift to decode ambiguous unions or unsupported versions differently. Preserve distinction between encode context and decode context (originator, compressor, schema, revision, isSummary); a context is not implicitly persisted by this layer. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:213-229` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:580-632`

## 7. Test assets to reuse

`src/test/codec/codec.spec.ts`, `src/test/codec/versioned/codec.spec.ts`; snapshot format tests under `src/test/snapshots`; `src/test/shared-tree/summaryLoad.integration.ts` with committed `summary-load-snapshots/singleTree-{Compressed,Uncompressed}-v2_0/v2_43/v2_52/v2_73/v2_74/v2_80/v2_117-1.json`. Check every format floor, rejected/unsafe overrides, absent versions, unknown versions, discontinued formats and roundtrips with a writer older than readable formats. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/codec/versioned/codec.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/shared-tree/summaryLoad.integration.ts:1`

## 8. Open questions

None. Runtime propagation is consumed at the kernel-args boundary documented above; no new negotiation or Swift-specific codec version is required.

