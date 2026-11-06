# Node Identifier — Fluid Framework 3.11.0

## 1. Role

Node identifier manager adapts runtime ID compressor identities into opaque node IDs. It is not a standalone UUID generator or wire codec. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifierManager.ts:46`

## 2. Surface used by other packages

NodeIdentifierManager, createNodeIdentifierManager, isStableNodeIdentifier, opaque LocalNodeIdentifier and StableNodeIdentifier types. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/index.ts:6`

## 3. Wire and persisted formats

None independently. Stable identifiers are UUID strings accepted by compressor isStableId; local opaque values wrap session-space compressed IDs. Special identifier fields encode through chunk field-batch SpecialField.Identifier (number in op-space or string, depending on context/finalization). `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifier.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifierManager.ts:92` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/nodeEncoder.ts:73`


## 4. Behavior

Generate→compressor.generateCompressedId. Localize stable→recompress (must already be known). Stabilize local→extract opaque number, decompress, assert stable ID. tryLocalize first requires compressor, checks stable syntax, then tryRecompress; invalid/unknown returns undefined without generation. An absent compressor does NOT enable a random UUID fallback. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifierManager.ts:54`

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/node-identifier/nodeIdentifier.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifier.ts:1-50`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface LocalNodeIdentifier
	extends Opaque<Brand<SessionSpaceCompressedId, "Local Node Identifier">> {}
export type StableNodeIdentifier = Brand<StableId, "Stable Node Identifier">;
export function compareLocalNodeIdentifiers(
	a: LocalNodeIdentifier,
	b: LocalNodeIdentifier,
): -1 | 0 | 1 {
	return a === b ? 0 : a > b ? 1 : -1;
}
export const nodeKeyTreeIdentifier: TreeNodeSchemaIdentifier = brand(
	"com.fluidframework.nodeIdentifier.NodeIdentifier",
);
```

### Decision procedure: `feature-libraries/node-identifier/nodeIdentifierManager.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifierManager.ts:1-96`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface NodeIdentifierManager {
	generateLocalNodeIdentifier(): LocalNodeIdentifier;
	localizeNodeIdentifier(identifier: StableNodeIdentifier): LocalNodeIdentifier;
	stabilizeNodeIdentifier(identifier: LocalNodeIdentifier): StableNodeIdentifier;
	tryLocalizeNodeIdentifier(identifier: string): LocalNodeIdentifier | undefined;
}
export function createNodeIdentifierManager(
	idCompressor?: IIdCompressor | undefined,
): NodeIdentifierManager {
	return new DefaultNodeIdentifierManager(idCompressor);
}
class DefaultNodeIdentifierManager implements NodeIdentifierManager {
	public constructor(private readonly idCompressor: IIdCompressor | undefined) {}
	public generateLocalNodeIdentifier(): LocalNodeIdentifier {
		assert(
			this.idCompressor !== undefined,
			0x6e4  ,
		);
		return brand(this.idCompressor.generateCompressedId());
	}
	public localizeNodeIdentifier(identifier: StableNodeIdentifier): LocalNodeIdentifier {
		assert(
			this.idCompressor !== undefined,
			0x6e5  ,
		);
		return brand(this.idCompressor.recompress(identifier));
	}
	public stabilizeNodeIdentifier(identifier: LocalNodeIdentifier): StableNodeIdentifier {
		assert(
			this.idCompressor !== undefined,
			0x6e6  ,
		);
		return brand(
			assertIsStableId(this.idCompressor.decompress(extractFromOpaque(identifier))),
		);
	}
	public tryLocalizeNodeIdentifier(identifier: string): LocalNodeIdentifier | undefined {
		assert(
			this.idCompressor !== undefined,
			0x6e9  ,
		);
		if (isStableNodeIdentifier(identifier)) {
			const compressedIdentifier = this.idCompressor.tryRecompress(identifier);
			if (compressedIdentifier !== undefined) {
				return brand(compressedIdentifier);
			}
		}
	}
}
export function isStableNodeIdentifier(
	identifier: string,
): identifier is StableNodeIdentifier {
	return isStableId(identifier);
}
```

## 5. Invariants and asserts

0x6e4 generate requires compressor; 0x6e5/0x6e6 convert requires compressor; 0x6e9 even tryLocalize requires compressor. Stabilize validates decompressed ID via assertIsStableId. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifierManager.ts:54`

## 6. JS-semantics hazards

Opaque local IDs preserve compressor session-space sign/identity; don't persist as if globally stable. tryLocalize distinguishes unknown from false/zero; do not use truthiness for compressed ID=0. Stable string validator is compressor's, not Foundation UUID's potentially different acceptance/normalization. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/nodeIdentifierManager.ts:78`

## 7. Test assets to reuse

Reuse real manager tests and mock manager only as deterministic test fixture, not production behavior. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/node-identifier/nodeIdentifier.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/node-identifier/mockNodeIdentifierManager.ts:6`

## 8. Open questions

None.

