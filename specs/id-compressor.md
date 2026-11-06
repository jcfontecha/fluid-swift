# id-compressor — native Swift port contract (3.11.0)

## 1. Role

Distributed UUID allocator and stable number mapping shared by the container and DDSes. Consensus orders creation ranges; local application state uses session space and persisted references use op space. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/types/idCompressor.ts:38-115`

## 2. Surface used by other packages

`IIdCompressor`, `IIdCompressorCore`, creation/deserialization/serialization helpers, stable/session/op/session-space branded IDs, creation ranges, serialization versions and shard tokens. Brand members are compile-time distinctions, not JSON properties. Exact declarations follow. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/index.ts:6-40`

### types/identifiers: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/types/identifiers.ts:1-51`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export type SessionSpaceCompressedId = number & {
	readonly SessionUnique: "cea55054-6b82-4cbf-ad19-1fa645ea3b3e";
};
export type OpSpaceCompressedId = number & {
	readonly OpNormalized: "9209432d-a959-4df7-b2ad-767ead4dbcae";
};
export type StableId = string & { readonly StableId: "53172b0d-a3d5-41ea-bd75-b43839c97f5a" };
export type SessionId = StableId & {
	readonly SessionId: "4498f850-e14e-4be9-8db0-89ec00997e58";
};
```

### types/idCompressor: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/types/idCompressor.ts:1-532`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export const SerializationVersion = {
	V2: 2,
	V3: 3,
} as const;
export type SerializationVersion =
	(typeof SerializationVersion)[keyof typeof SerializationVersion];
export interface IIdCompressorCore {
	readonly events: Listenable<IdCompressorEvents>;
	takeNextCreationRange(): IdCreationRange;
	takeUnfinalizedCreationRange(): IdCreationRange;
	resetUnfinalizedCreationRange(): void;
	finalizeCreationRange(range: IdCreationRange): void;
	beginGhostSession(ghostSessionId: SessionId, ghostSessionCallback: () => void): void;
	shard(newShardCount: number): SerializedIdCompressorShard[];
	synchronizeWithShard(syncToken: ShardSynchronizationToken): void;
	getChildShardSyncToken(
		childToken: ShardSynchronizationToken,
	): ParentShardSynchronizationToken;
	synchronizeWithParent(token: ParentShardSynchronizationToken): void;
	getShardSyncToken(): ShardSynchronizationToken | undefined;
	disposeShard(): ShardSynchronizationToken | undefined;
	serialize(withSession: true): SerializedIdCompressorWithOngoingSession;
	serialize(withSession: false): SerializedIdCompressorWithNoSession;
}
export interface SerializedIdCompressorShard {
	readonly serialized: SerializedIdCompressorWithOngoingSession;
	readonly syncToken: ShardSynchronizationToken;
}
export interface ShardToken {
	localGenCount: number;
	shardId: SessionId;
	disposed: boolean;
}
export type ShardSynchronizationToken = ShardToken & {
	readonly ShardSynchronizationToken: "c79724e1-9103-4415-95b5-bebb932be404";
};
export interface ParentShardSynchronizationToken
	extends Readonly<Omit<ShardToken, "disposed">> {
	readonly type: "parentIdSpaceShardSyncToken";
}
export interface IdCompressorEvents {
	rangeFinalized: (range: IdCreationRange) => void;
}
export interface IIdCompressor {
	localSessionId: SessionId;
	generateCompressedId(): SessionSpaceCompressedId;
	generateDocumentUniqueId(): (SessionSpaceCompressedId & OpSpaceCompressedId) | StableId;
	normalizeToOpSpace(id: SessionSpaceCompressedId): OpSpaceCompressedId;
	normalizeToSessionSpace(
		id: OpSpaceCompressedId,
		originSessionId: SessionId,
	): SessionSpaceCompressedId;
	tryNormalizeToSessionSpaceWithoutSession(
		id: OpSpaceCompressedId,
	): SessionSpaceCompressedId | undefined;
	decompress(id: SessionSpaceCompressedId): StableId;
	recompress(uncompressed: StableId): SessionSpaceCompressedId;
	tryRecompress(uncompressed: StableId): SessionSpaceCompressedId | undefined;
}
```

### types/persisted-types/0.0.1: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/types/persisted-types/0.0.1.ts:1-63`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export type SerializedIdCompressor = string & {
	readonly _serializedIdCompressor: "8c73c57c-1cf4-4278-8915-6444cb4f6af5";
};
export type SerializedIdCompressorWithNoSession = SerializedIdCompressor & {
	readonly _noLocalState: "3aa2e1e8-cc28-4ea7-bc1a-a11dc3f26dfb";
};
export type SerializedIdCompressorWithOngoingSession = SerializedIdCompressor & {
	readonly _hasLocalState: "1281acae-6d14-47e7-bc92-71c8ee0819cb";
};
export interface IdCreationRange {
	readonly sessionId: SessionId;
	readonly ids?: {
		readonly firstGenCount: number;
		readonly count: number;
		readonly requestedClusterSize: number;
		readonly localIdRanges: [genCount: number, count: number][];
	};
}
```



## 3. Wire and persisted formats

### Creation-range messages

The compressor returns an object, not a self-submitting transport op. Empty is exactly `{sessionId: string}`; `ids` is absent, not null. Nonempty insertion order is `sessionId`, `ids`; inside `ids`: `firstGenCount: number`, `count: number`, `requestedClusterSize: number`, `localIdRanges: [number,number][]`. Each pair is a leading generation count and run length, including only positions generated in negative/local form. Example after generating two IDs in a fresh session S: `{"sessionId":"00000000-0000-4000-8000-000000000000","ids":{"firstGenCount":1,"count":2,"requestedClusterSize":512,"localIdRanges":[[1,2]]}}`. Taking again without generating produces only `sessionId`. The caller sequences ranges in take order and finalizes on every participant before consuming dependent IDs. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:528-599`

### Binary persistence, exact slot layout

Output is base64 of one typed-array backing buffer. A slot is eight bytes. Ordinary slots are IEEE-754 binary64 in the host typed-array byte order (little-endian on the supported JS oracle hosts). UUIDs are **not UUID text bytes**: remove the fixed version/variant bits to obtain the numeric UUID; write its low unsigned 64-bit limb first, then its high unsigned 64-bit limb. Within each limb the native typed-array byte order applies. Boolean is double 1 or 0; reader recognizes exactly 1 as true, every other numeric value as false. No lengths, padding or checksum outside these slots. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/persistanceUtilities.ts:9-63`

Offsets, in bytes, before variable tails:

| Offset | Encoding | Value |
| --- | --- | --- |
| 0 | f64 | write version 2 or 3 |
| 8 | f64 | hasLocalState 0/1 |
| 16 | f64 | session count S |
| 24 | f64 | cluster count C |
| 32 + 16i | u64 low, u64 high | numeric session UUID, i in [0,S) |
| 32 + 16S + 24j | f64 triple | session index, capacity, finalized count, j in [0,C) |

Sessions are in insertion order; without local state empty sessions are filtered; with local state all are retained and the first is the local session. Clusters are in global final-space allocation order. Base final/local IDs are not written: reconstruct base final by cumulative capacities starting at zero; per-session local base advances by previous cluster capacity. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:881-940`

If `hasLocalState=0`, the buffer ends after cluster triples. Otherwise append `localGenCount`, `nextRangeBaseGenCount`, `normalizerPairCount` as f64, followed by f64 `(leadingGenCount,count)` pairs in increasing generation order. V2 ends here. V3 appends f64 `hasShardingState`. If true append f64 `currentStride`, f64 `originalStride`, f64 active-child count, each active child UUID as two u64 limbs in Set insertion order, f64 `hasShardId`, and the two-limb shard UUID only if that flag is true. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:942-988`

Reader accepts versions 2 and 3. V1 throws `IdCompressor version 1.0 is no longer supported.`; any other version throws `Unknown IdCompressor serialized version.` Effective write version after reading is `max(requestedWriteVersion, serializedVersion)`. A no-local-state read requires a new session ID and prepends that session, adding one to every stored session index. A local-state read forbids supplying a new session ID. Reader must consume the entire buffer. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:991-1125`

Concrete byte fixture from the fresh S=`00000000-0000-4000-8000-000000000000` constructor, explicit V2: with local state slots are `[2,1,1,0, u64(0),u64(0), 0,1,0]` (72 bytes); without local state slots are `[2,0,0,0]` (32 bytes). V3 fresh local state adds a final zero f64 `hasShardingState` (80 bytes). Fresh no-local V3 is `[3,0,0,0]` (32 bytes). Numeric UUID zero reconstructs the stated UUID, not the all-zero UUID. These follow constructor initialization and writer traversal. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:107-205` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:874-988` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/utilities.ts:139-184`

### Literal byte examples and offset equations

Let B=32+16S+24C. Without local state length=B. With local state and P normalizer pairs, V2 length=B+24+16P; localGenCount at B, nextRangeBaseGenCount at B+8, P at B+16, pair i at B+24+16i. V3 has hasShardingState flag at T=B+24+16P; false length=T+8. True: currentStride at T+8, originalStride at T+16, activeChildCount A at T+24, A UUIDs starting T+32 with16-byte stride, hasShardId at T+32+16A, optional shard UUID at T+40+16A. Total length T+40+16A without shard ID, T+56+16A with it. All offsets are bytes. UUID limbs use u64 reinterpretation, not numeric conversion to/from f64. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:890-980`

For S=`00000000-0000-4000-8000-000000000000` (numeric UUID zero), writer-derived little-endian fixtures follow; after-two means generate twice, take range, finalize it, requestedClusterSize default512. Only these particular UUID words happen to have zero bits and thus also look like f64 zero; nonzero limbs still encode as u64.

- V2 empty summary: 32 bytes; eight-byte words in file order `0000000000000040 0000000000000000 0000000000000000 0000000000000000`; base64 `AAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`.
- V2 empty ongoing session: 72 bytes; eight-byte words in file order `0000000000000040 000000000000f03f 000000000000f03f 0000000000000000 0000000000000000 0000000000000000 0000000000000000 000000000000f03f 0000000000000000`; base64 `AAAAAAAAAEAAAAAAAADwPwAAAAAAAPA/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAAAA`.
- V2 S after finalizing two IDs, summary: 72 bytes; eight-byte words in file order `0000000000000040 0000000000000000 000000000000f03f 000000000000f03f 0000000000000000 0000000000000000 0000000000000000 0000000000108040 0000000000000040`; base64 `AAAAAAAAAEAAAAAAAAAAAAAAAAAAAPA/AAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCAQAAAAAAAAABA`.
- V2 S after finalizing two IDs, ongoing: 112 bytes; eight-byte words in file order `0000000000000040 000000000000f03f 000000000000f03f 000000000000f03f 0000000000000000 0000000000000000 0000000000000000 0000000000108040 0000000000000040 0000000000000040 0000000000000840 000000000000f03f 000000000000f03f 0000000000000040`; base64 `AAAAAAAAAEAAAAAAAADwPwAAAAAAAPA/AAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCAQAAAAAAAAABAAAAAAAAAAEAAAAAAAAAIQAAAAAAAAPA/AAAAAAAA8D8AAAAAAAAAQA==`.

Fresh counters are localGenCount=0,nextRangeBaseGenCount=1; two negatives form normalizer pair(1,2), taking moves nextRangeBaseGenCount to3, finalizing creates capacity514/count2 at final base0. Summary omits local counters/normalizer. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:107-118` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:214-265` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:528-689` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:874-988`

### Container allocation op and reconnect protocol

Runtime allocation op is `{type:"idAllocation",contents:IdCreationRange}` (type then contents), e.g. `{"type":"idAllocation","contents":{"sessionId":"00000000-0000-4000-8000-000000000000","ids":{"firstGenCount":1,"count":2,"requestedClusterSize":512,"localIdRanges":[[1,2]]}}}`. Compressor does not submit it. Runtime callback skips absent compressor and empty range; returns `{runtimeOp,referenceSequenceNumber:lastSequenceNumber,staged:false}`. After any batch rebase and only when shouldSend() && !staged, outbox takes allocation just-in-time, prepends to rawBatch.messages, adds batch metadata, virtualizes and sends. Disconnected/staged flush takes no allocation range. Thus dependent IDs sequence after allocation, which receives first-of-batch metadata. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/messageTypes.ts:26-50` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/messageTypes.ts:124-127` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2292-2310` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/opLifecycle/outbox.ts:442-477`

Before pending replay runtime resets unfinalized cursor: no local cluster→1, otherwise generation at lastCluster.baseLocalId-lastCluster.count. Old allocation ops are **not resubmitted/rebased**; replacement allocation covers all remaining unfinalized IDs including newly generated replay IDs. Stashed allocation application is ignored because pending state includes compressor tip; do not finalize twice. Inbound saved ops skip only if skipSavedCompressorOps && savedOp===true. Otherwise compressor absent→require schema mode and queue range; present→require pending queue empty and finalize in collection order. Delayed load creates compressor, clears pending queue, finalizes saved queue in order. Detached attach summary takes/finalizes the initial range locally, asserting missing ids OR firstGenCount==1. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:562-584` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3044-3053` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3084-3100` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3122-3148` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3777-3802` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:4335-4343` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:5559-5568`

### Shard cross-executor payloads

Child-to-parent token insertion order is `localGenCount: number`, `shardId: SessionId`, `disposed: boolean`. Parent-to-child token has its exact literal discriminator `type: "parentIdSpaceShardSyncToken"`, child `shardId` and generation count as constructed in the ordered algorithm below. `SerializedIdCompressorShard` has `serialized` then `syncToken`. These are in-process/marshalling contracts, not an additional Fluid wire envelope. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:303-518`


## 4. Behavior

### ID space math and allocation

Generation counts start at 1; local ID L=-g. Stable UUID for generation g is `stableIdFromNumericUuid(sessionNumeric + BigInt(g-1))`. The numeric UUID is a 122-bit packing, removing four fixed version bits and two variant bits; unpack reintroduces v4 and RFC4122 variant. The exact masks, shifts and formatting are included below. Do not increment a textual 128-bit UUID directly across the fixed bits. Final IDs are nonnegative numbers; cluster `(baseFinalId F, baseLocalId L, capacity K, count N)` aligns local l to final `F + (L-l)` and final f to local `L-(f-F)`. Allocated is the half-open final interval `[F,F+K)`; finalized is `[F,F+N)`. Local session clusters advance local base by capacity, not by count. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/utilities.ts:133-196` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessions.ts:15-410`

In ordinary generation increment `localGenCount` first. If the local session has no cluster or its last cluster lacks room at that generation, record a negative local in the normalizer and return it. Otherwise return the eager final aligned to the reserved position; do not put it in the negative-ID normalizer. Negative session IDs never change form in that session's application data after finalization. Sharded generation disables eager finals, records a whole stride as local, advances generation by stride, returns negative new generation. Ghost generation creates capacity-one cluster on the first call, thereafter grows the same cluster by one and increments count; returns the last finalized final immediately. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:214-267`

### Finalization, in execution order

1. Reject a ghost context. Missing `ids` returns immediately without event. Validate positive count and requested capacity; capacity request must be <=2^20.
2. Get/create session, compute range base `-firstGenCount`. First range must begin at -1; create capacity `requestedClusterSize + count` with count zero. Local first-cluster telemetry fires now.
3. Require `lastCluster.baseLocalId-lastCluster.count == rangeBaseLocal`, otherwise throw `Ranges finalized out of order` with expected and actual starts.
4. If count fits remaining capacity, add it to finalized count. Otherwise overflow=count-remaining; additional reservation=overflow+requestedClusterSize. If this session's last cluster is globally last, grow that cluster capacity by the reservation and count by count, assert no UUID collision, then local expansion telemetry. Otherwise fill old count to capacity, allocate a new global-tail cluster with reservation capacity and overflow finalized count, then local new-cluster telemetry.
5. For local finalization emit status telemetry and reset both telemetry counters. Assert session nonempty, then synchronously emit `rangeFinalized(range)`. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:601-708`

### Normalization and conversion

Op normalization leaves nonnegative IDs unchanged. Negative IDs must occur in the normalizer, then convert through the local cluster's **allocated** capacity when possible, or remain negative. Session normalization first handles nonnegative IDs: in a local allocated cluster return aligned negative if normalizer contains it, otherwise require generation <=localGenCount and retain final; outside local clusters require below global finalized limit and retain final. Negative from own origin must have been generated as local; negative remote origin requires a known remote session and conversion using finalized count, not reservation. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:710-787`

Decompression locates a global cluster for finals, rejects an unfinalized remote reserved ID, and asserts an unfinalized local eager final is not in the normalizer; then UUID offset is generation-1. Negative decompression requires normalizer membership. Recompression first searches UUID-ordered session clusters, otherwise tests the local UUID offset and negative normalizer; own clustered IDs prefer recorded negative form, then eager final. Preserve the remote branch's actual numeric comparison in `tryRecompress` below even though its operand mixes positive generation and negative local-ID notation. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:789-870`

### Persistence does not retain every runtime field

Write version is explicit at create/deserialization entry points, not inferred from package version; reading uses max(requested,stored). Cluster request512 is a constructor default and is not serialized, nor are telemetry counters, logger, event listeners, ghost context or derived caches. A restored compressor starts with that request default even if the original private request was changed. maxClusterSize=2^20 bounds **requestedClusterSize**, not the actual capacity=request+count or later expanded capacity. Read-side boolean accepts only f64 value1; other numeric values are false. Malformed byte length fails typed-array construction before slot parsing; exhausted slot reads assert, leftover slots assert0x75f. Do not infer a V1 reader from the presence of v2/v3 snapshot directories: only serialized versions2,3 are supported. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:107-195` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:587-598` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:874-1125` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/persistanceUtilities.ts:44-63`

### Two-client numeric trace and distinct state sets

Fresh S generates -1,-2 (UUID S+0,S+1), takes first=1,count=2,requested512 and finalizes: cluster F=0,L=-1,K=514,N=2. S still holds session IDs -1,-2; normalizeToOpSpace maps them to0,1. S's next generated ID is eager final2 (generation3), absent from normalizer, which contains only generations1,2. Other T finalizes S's range before normalizing S's negative ops; final0 remains T session ID0 but becomes S session ID-1. T's own first negative -1 denotes T's UUID, not S's. T's first count1 range reserves final base514, not2. Subsequent S overflow must allocate at global tail rather than expand through T's space. generateDocumentUniqueId returns UUID for a generated negative, otherwise the final number. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:214-272` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:601-787`

Keep reserved positions (capacity), finalized positions (count), and local-negative runs (normalizer) distinct. Local negative identity is not rewritten on acknowledgment. localIdRanges is emitted for consumers, but finalizeCreationRange does not ingest it into a remote normalizer: it mutates using sessionId,firstGenCount,count,requestedClusterSize. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:528-689`

### Complete ordered algorithms

These contracts include binary search boundary choices, collision checks, sharding synchronization/backfill/disposal, ghost-session cleanup and all public entry-point defaults. They also provide the literal parent token field order. Each listing is complete rather than a call-site reference.


### identifiers: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/identifiers.ts:1-52`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export type FinalCompressedId = number & {
	readonly FinalCompressedId: "5d83d1e2-98b7-4e4e-a889-54c855cfa73d";
	readonly OpNormalized: "9209432d-a959-4df7-b2ad-767ead4dbcae";
};
export type LocalCompressedId = number & {
	readonly LocalCompressedId: "6fccb42f-e2a4-4243-bd29-f13d12b9c6d1";
} & SessionSpaceCompressedId;
export function isFinalId(
	id: SessionSpaceCompressedId | OpSpaceCompressedId,
): id is FinalCompressedId {
	return id >= 0;
}
export type NumericUuid = bigint & {
	readonly NumericUuid: "be04dd4d-9d7e-4337-a833-eec64c61aa46";
};
```

### utilities: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/utilities.ts:1-196`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
const hexadecimalCharCodes = [..."09afAF"].map((c) => c.codePointAt(0)) as [
	zero: number,
	nine: number,
	a: number,
	f: number,
	A: number,
	F: number,
];
function isHexadecimalCharacter(charCode: number): boolean {
	return (
		(charCode >= hexadecimalCharCodes[0] && charCode <= hexadecimalCharCodes[1]) ||
		(charCode >= hexadecimalCharCodes[2] && charCode <= hexadecimalCharCodes[3]) ||
		(charCode >= hexadecimalCharCodes[4] && charCode <= hexadecimalCharCodes[5])
	);
}
export function createSessionId(): SessionId {
	return assertIsStableId(v4()) as SessionId;
}
export function assertIsStableId(stableId: string): StableId {
	assert(isStableId(stableId), 0x4a3 );
	return stableId;
}
export function assertIsSessionId(stableId: string): SessionId {
	assertIsStableId(stableId);
	return stableId as SessionId;
}
export function generateStableId(): StableId {
	return assertIsStableId(v4());
}
export function isStableId(str: string): str is StableId {
	if (str.length !== 36) {
		return false;
	}
	for (let i = 0; i < str.length; i++) {
		switch (i) {
			case 8:
			case 13:
			case 18:
			case 23: {
				if (str.charAt(i) !== "-") {
					return false;
				}
				break;
			}
			case 14: {
				if (str.charAt(i) !== "4") {
					return false;
				}
				break;
			}
			case 19: {
				const char = str.charAt(i);
				if (char !== "8" && char !== "9" && char !== "a" && char !== "b") {
					return false;
				}
				break;
			}
			default: {
				const codePoint = str.codePointAt(i);
				assert(codePoint !== undefined, 0xaaf );
				if (!isHexadecimalCharacter(codePoint)) {
					return false;
				}
				break;
			}
		}
	}
	return true;
}
export function compareFiniteNumbers<T extends number>(a: T, b: T): number {
	return a - b;
}
export function compareStrings<T extends string>(a: T, b: T): number {
	return a > b ? 1 : a === b ? 0 : -1;
}
export function compareBigints<T extends bigint>(a: T, b: T): number {
	return a > b ? 1 : a === b ? 0 : -1;
}
export function genCountFromLocalId(localId: LocalCompressedId): number {
	return -localId;
}
export function localIdFromGenCount(genCount: number): LocalCompressedId {
	return -genCount as LocalCompressedId;
}
const versionMask = 0x4n << (19n * 4n);
const variantMask = 0x8n << (15n * 4n);
const upperMask = 0xffffffffffffn << (20n * 4n);
const strippedUpperMask = upperMask >> 6n;
const middieBittiesMask = 0xfffn << (16n * 4n);
const strippedMiddieBittiesMask = middieBittiesMask >> 2n;
const lowerMask = 0x3fffffffffffffffn;
export function numericUuidFromStableId(stableId: StableId): NumericUuid {
	const uuidU128 = BigInt(`0x${stableId.replace(/-/g, "")}`);
	const upperMasked = uuidU128 & upperMask;
	const middieBittiesMasked = uuidU128 & middieBittiesMask;
	const lowerMasked = uuidU128 & lowerMask;
	const upperMaskedPlaced = upperMasked >> 6n;
	const middieBittiesMaskedPlaced = middieBittiesMasked >> 2n;
	const id = upperMaskedPlaced | middieBittiesMaskedPlaced | lowerMasked;
	return id as NumericUuid;
}
export function stableIdFromNumericUuid(numericUuid: NumericUuid): StableId {
	const upperMasked = (numericUuid & strippedUpperMask) << 6n;
	const middieBittiesMasked = (numericUuid & strippedMiddieBittiesMask) << 2n;
	const lowerMasked = numericUuid & lowerMask;
	const uuidU128 = upperMasked | versionMask | middieBittiesMasked | variantMask | lowerMasked;
	const uuidString = uuidU128.toString(16).padStart(32, "0");
	return `${uuidString.slice(0, 8)}-${uuidString.slice(8, 12)}-${uuidString.slice(
		12,
		16,
	)}-${uuidString.slice(16, 20)}-${uuidString.slice(20, 32)}` as StableId;
}
export function offsetNumericUuid(numericUuid: NumericUuid, offset: number): NumericUuid {
	return (numericUuid + BigInt(offset)) as NumericUuid;
}
export function subtractNumericUuids(a: NumericUuid, b: NumericUuid): NumericUuid {
	return (a - b) as NumericUuid;
}
export function addNumericUuids(a: NumericUuid, b: NumericUuid): NumericUuid {
	return (a + b) as NumericUuid;
}
```

### appendOnlySortedMap: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/appendOnlySortedMap.ts:1-381`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class AppendOnlySortedMap<K, V> {
	protected readonly elements: (K | V)[] = [];
	public constructor(protected readonly comparator: (a: K, b: K) => number) {}
	public get size(): number {
		return this.elements.length / 2;
	}
	public minKey(): K | undefined {
		return this.elements[0] as K | undefined;
	}
	public maxKey(): K | undefined {
		return this.elements[this.elements.length - 2] as K | undefined;
	}
	public minValue(): V | undefined {
		return this.elements[1] as V | undefined;
	}
	public maxValue(): V | undefined {
		return this.elements[this.elements.length - 1] as V | undefined;
	}
	public first(): [K, V] | undefined {
		const { elements } = this;
		const { length } = elements;
		if (length === 0) {
			return undefined;
		}
		return [elements[0] as K, elements[1] as V];
	}
	public last(): [K, V] | undefined {
		const { elements } = this;
		const { length } = elements;
		if (length === 0) {
			return undefined;
		}
		const lastKeyIndex = length - 2;
		return [elements[lastKeyIndex] as K, elements[lastKeyIndex + 1] as V];
	}
	public getAtIndex(index: number): [K, V] | undefined {
		const realIndex = index * 2;
		const { elements } = this;
		if (realIndex < 0 || realIndex > elements.length - 1) {
			return undefined;
		}
		return [elements[realIndex] as K, elements[realIndex + 1] as V];
	}
	public *entries(): IterableIterator<readonly [K, V]> {
		const { elements } = this;
		for (let i = 0; i < elements.length; i += 2) {
			yield [elements[i] as K, elements[i + 1] as V];
		}
	}
	public *keys(): IterableIterator<K> {
		const { elements } = this;
		for (let i = 0; i < elements.length; i += 2) {
			yield elements[i] as K;
		}
	}
	public *values(): IterableIterator<V> {
		const { elements } = this;
		for (let i = 0; i < elements.length; i += 2) {
			yield elements[i + 1] as V;
		}
	}
	public *entriesReversed(): IterableIterator<readonly [K, V]> {
		const { elements } = this;
		for (let i = elements.length - 2; i >= 0; i -= 2) {
			yield [elements[i] as K, elements[i + 1] as V];
		}
	}
	public append(key: K, value: V): void {
		const { elements } = this;
		const { length } = elements;
		if (length !== 0 && this.comparator(key, this.maxKey() as K) <= 0) {
			throw new Error("Inserted key must be > all others in the map.");
		}
		elements.push(key, value);
	}
	public replaceLast(key: K, value: V): void {
		const { elements, comparator } = this;
		const { length } = elements;
		if (length !== 0) {
			elements.pop();
			elements.pop();
			if (comparator(key, this.maxKey() as K) <= 0) {
				throw new Error("Inserted key must be > all others in the map.");
			}
		}
		elements.push(key, value);
	}
	public get(key: K): V | undefined {
		const index = AppendOnlySortedMap.keyIndexOf(this.elements, key, this.comparator);
		if (index < 0) {
			return undefined;
		}
		return this.elements[index + 1] as V;
	}
	public getPairOrNextLower(key: K): readonly [K, V] | undefined {
		return this.getPairOrNextLowerBy(key, this.comparator);
	}
	public getPairOrNextHigher(key: K): readonly [K, V] | undefined {
		return this.getPairOrNextHigherBy(key, this.comparator);
	}
	public equals(
		other: AppendOnlySortedMap<K, V>,
		compareValues: (a: V, b: V) => boolean,
	): boolean {
		if (other === this) {
			return true;
		}
		if (this.elements.length !== other.elements.length) {
			return false;
		}
		for (let i = this.elements.length - 2; i >= 0; i -= 2) {
			const keyThis = this.elements[i] as K;
			const valueThis = this.elements[i + 1] as V;
			const keyOther = other.elements[i] as K;
			const valueOther = other.elements[i + 1] as V;
			if (this.comparator(keyThis, keyOther) !== 0) {
				return false;
			}
			if (!compareValues(valueThis, valueOther)) {
				return false;
			}
		}
		return true;
	}
	public assertValid(): void {
		let prev: readonly [K, unknown] | undefined;
		for (const kv of this.entries()) {
			if (prev !== undefined) {
				assert(this.comparator(kv[0], prev[0]) > 0, 0x752 );
			}
			prev = kv;
		}
	}
	public *getRange(from: K, to: K): IterableIterator<readonly [K, V]> {
		const keyIndexFrom = this.getKeyIndexOfOrNextHigher(from, this.comparator);
		if (keyIndexFrom === undefined) {
			return;
		}
		const keyIndexTo = this.getKeyIndexOfOrNextLower(to, this.comparator);
		if (keyIndexTo === undefined) {
			return;
		}
		for (let i = keyIndexFrom; i <= keyIndexTo; i += 2) {
			yield [this.elements[i] as K, this.elements[i + 1] as V];
		}
	}
	protected getPairOrNextLowerBy<T>(
		search: T,
		comparator: (search: T, key: K, value: V) => number,
	): readonly [K, V] | undefined {
		const keyIndex = this.getKeyIndexOfOrNextLower(search, comparator);
		if (keyIndex === undefined) {
			return undefined;
		}
		return [this.elements[keyIndex] as K, this.elements[keyIndex + 1] as V];
	}
	private getKeyIndexOfOrNextLower<T>(
		search: T,
		comparator: (search: T, key: K, value: V) => number,
	): number | undefined {
		const { elements } = this;
		if (elements.length === 0) {
			return undefined;
		}
		let keyIndex = AppendOnlySortedMap.keyIndexOf(elements, search, comparator);
		if (keyIndex < 0) {
			keyIndex ^= AppendOnlySortedMap.failureXor;
			if (keyIndex > 0) {
				return keyIndex - 2;
			}
			return undefined;
		}
		return keyIndex;
	}
	protected getPairOrNextHigherBy<T>(
		search: T,
		comparator: (search: T, key: K, value: V) => number,
	): readonly [K, V] | undefined {
		const keyIndex = this.getKeyIndexOfOrNextHigher(search, comparator);
		if (keyIndex === undefined) {
			return undefined;
		}
		return [this.elements[keyIndex] as K, this.elements[keyIndex + 1] as V];
	}
	private getKeyIndexOfOrNextHigher<T>(
		search: T,
		comparator: (search: T, key: K, value: V) => number,
	): number | undefined {
		const { elements } = this;
		const { length } = elements;
		if (length === 0) {
			return undefined;
		}
		let keyIndex = AppendOnlySortedMap.keyIndexOf(elements, search, comparator);
		if (keyIndex < 0) {
			keyIndex ^= AppendOnlySortedMap.failureXor;
			if (keyIndex < length) {
				return keyIndex;
			}
			return undefined;
		}
		return keyIndex;
	}
	public static readonly failureXor = -1;
	public static keyIndexOf<T, K, V>(
		elements: readonly (K | V)[],
		search: T,
		comparator: (search: T, key: K, value: V) => number,
	): number {
		let low = 0;
		let high = elements.length / 2;
		let mid = high >> 1;
		while (low < high) {
			const keyIndex = mid * 2;
			const c = comparator(search, elements[keyIndex] as K, elements[keyIndex + 1] as V);
			if (c > 0) {
				low = mid + 1;
			} else if (c < 0) {
				high = mid;
			} else if (c === 0) {
				return keyIndex;
			} else {
				throw new Error("Invalid comparator.");
			}
			mid = (low + high) >> 1;
		}
		return (mid * 2) ^ AppendOnlySortedMap.failureXor;
	}
}
```

### sessionSpaceNormalizer: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessionSpaceNormalizer.ts:1-158`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class SessionSpaceNormalizer {
	private readonly localIdRanges = new AppendOnlySortedMap<number, number>(
		compareFiniteNumbers,
	);
	public get idRanges(): Pick<AppendOnlySortedMap<number, number>, "size" | "entries"> {
		return this.localIdRanges;
	}
	public getRangesBetween(
		firstGenCount: number,
		lastGenCount: number,
	): [genCount: number, count: number][] {
		const ranges: [genCount: number, count: number][] = [];
		let firstRange = this.localIdRanges.getPairOrNextLower(firstGenCount);
		if (firstRange === undefined || !this.rangeContains(firstRange, firstGenCount)) {
			firstRange = this.localIdRanges.getPairOrNextHigher(firstGenCount);
			if (firstRange === undefined) {
				return ranges;
			}
		}
		for (const [genCount, count] of this.localIdRanges.getRange(firstRange[0], lastGenCount)) {
			ranges.push([genCount, count]);
		}
		if (ranges.length === 0) {
			return ranges;
		}
		assert(
			ranges[0] !== undefined,
			0x9dd ,
		);
		const [baseGenCount, baseCount] = ranges[0];
		if (this.rangeContains(ranges[0], firstGenCount)) {
			ranges[0] = [firstGenCount, baseCount - (firstGenCount - baseGenCount)];
			assert(
				this.rangeContains(ranges[0], firstGenCount),
				0x952 ,
			);
		} else {
			assert(
				baseGenCount > firstGenCount,
				0x953 ,
			);
		}
		const lastRangeIndex = ranges.length - 1;
		const lastRange = ranges[lastRangeIndex];
		assert(
			lastRange !== undefined,
			0x9de ,
		);
		const [limitGenCount, limitCount] = lastRange;
		if (this.rangeContains(lastRange, lastGenCount)) {
			ranges[lastRangeIndex] = [limitGenCount, lastGenCount - limitGenCount + 1];
			assert(
				this.rangeContains(lastRange, lastGenCount),
				0x954 ,
			);
		} else {
			assert(
				limitGenCount + limitCount - 1 < lastGenCount,
				0x955 ,
			);
		}
		return ranges;
	}
	private rangeContains(range: readonly [number, number], genCount: number): boolean {
		const [baseGenCount, count] = range;
		return genCount >= baseGenCount && genCount < baseGenCount + count;
	}
	public addLocalRange(baseGenCount: number, count: number): void {
		const last = this.localIdRanges.last();
		if (last !== undefined) {
			const [lastGenCount, lastCount] = last;
			if (lastGenCount + lastCount === baseGenCount) {
				this.localIdRanges.replaceLast(lastGenCount, lastCount + count);
				return;
			}
		}
		this.localIdRanges.append(baseGenCount, count);
	}
	public contains(query: LocalCompressedId): boolean {
		const genCount = genCountFromLocalId(query);
		const containingBlock = this.localIdRanges.getPairOrNextLower(genCount);
		if (containingBlock !== undefined) {
			const [baseGenCount, count] = containingBlock;
			if (genCount <= baseGenCount + (count - 1)) {
				return true;
			}
		}
		return false;
	}
	public equals(other: SessionSpaceNormalizer): boolean {
		return this.localIdRanges.equals(
			other.localIdRanges,
			(countA, countB) => countA === countB,
		);
	}
}
```

### sessions: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessions.ts:1-410`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class Sessions {
	private readonly uuidSpace = new BTree<NumericUuid, Session>(undefined, compareBigints);
	private readonly sessionCache = new Map<SessionId, Session>();
	public constructor(sessions?: [sessionBase: NumericUuid, session: Session][]) {
		if (sessions !== undefined) {
			for (const [numeric, session] of sessions) {
				this.sessionCache.set(stableIdFromNumericUuid(numeric) as SessionId, session);
			}
			this.uuidSpace = new BTree(sessions, compareBigints);
			if (
				this.sessionCache.size !== sessions.length ||
				sessions.length !== this.uuidSpace.size
			) {
				throw new Error("Cannot resume existing session.");
			}
		}
	}
	public sessions(): IterableIterator<Session> {
		return this.sessionCache.values();
	}
	public getOrCreate(sessionId: SessionId): Session {
		const existing = this.sessionCache.get(sessionId);
		if (existing !== undefined) {
			return existing;
		}
		const session = new Session(sessionId);
		assert(
			this.uuidSpace.set(session.sessionUuid, session),
			0x760 ,
		);
		this.sessionCache.set(sessionId, session);
		return session;
	}
	public get(sessionId: SessionId): Session | undefined {
		return this.sessionCache.get(sessionId);
	}
	public getContainingCluster(
		query: StableId,
	): [cluster: IdCluster, alignedLocal: LocalCompressedId] | undefined {
		const numericStable = numericUuidFromStableId(query);
		const possibleMatch = this.uuidSpace.getPairOrNextLower(numericStable);
		if (possibleMatch === undefined) {
			return undefined;
		}
		const [_, session] = possibleMatch;
		const numericDelta = subtractNumericUuids(numericStable, session.sessionUuid);
		if (numericDelta > Number.MAX_SAFE_INTEGER) {
			return undefined;
		}
		const alignedLocal = localIdFromGenCount(Number(numericDelta) + 1);
		const containingCluster = session.getClusterByLocal(alignedLocal, true);
		if (containingCluster === undefined) {
			return undefined;
		}
		return [containingCluster, alignedLocal];
	}
	public clusterCollides(cluster: IdCluster): boolean {
		const { session: owningSession, baseLocalId, capacity } = cluster;
		const clusterBaseNumeric = offsetNumericUuid(
			owningSession.sessionUuid,
			genCountFromLocalId(baseLocalId) - 1,
		);
		const clusterMaxNumeric = offsetNumericUuid(clusterBaseNumeric, capacity - 1);
		let closestMatch: [NumericUuid, Session] | undefined =
			this.uuidSpace.getPairOrNextLower(clusterMaxNumeric);
		while (closestMatch !== undefined && closestMatch[1] === owningSession) {
			closestMatch = this.uuidSpace.nextLowerPair(closestMatch[0]);
		}
		if (closestMatch === undefined) {
			return false;
		}
		const [_, session] = closestMatch;
		assert(session !== owningSession, 0x761 );
		const lastCluster = session.getLastCluster();
		if (lastCluster === undefined) {
			return false;
		}
		const lastAllocatedNumeric = offsetNumericUuid(
			session.sessionUuid,
			genCountFromLocalId(lastAllocatedLocal(lastCluster)) - 1,
		);
		return lastAllocatedNumeric >= clusterBaseNumeric;
	}
	public equals(other: Sessions, includeLocalState: boolean): boolean {
		const checkIsSubset = (sessionsA: Sessions, sessionsB: Sessions): boolean => {
			const first = sessionsA.sessions().next();
			const firstSessionThis = first.done ? undefined : first.value;
			for (const [stableId, session] of sessionsA.sessionCache.entries()) {
				const otherSession = sessionsB.sessionCache.get(stableId);
				if (otherSession === undefined) {
					if (!session.isEmpty() || includeLocalState) {
						return false;
					}
					assert(
						session === firstSessionThis,
						0x762 ,
					);
				} else if (!session.equals(otherSession)) {
					return false;
				}
			}
			return true;
		};
		return checkIsSubset(this, other) && checkIsSubset(other, this);
	}
}
export class Session {
	private readonly clusterChain: IdCluster[] = [];
	public readonly sessionUuid: NumericUuid;
	public constructor(sessionId: SessionId | NumericUuid) {
		this.sessionUuid =
			typeof sessionId === "string" ? numericUuidFromStableId(sessionId) : sessionId;
	}
	public addNewCluster(
		baseFinalId: FinalCompressedId,
		capacity: number,
		count: number,
	): IdCluster {
		const lastCluster = this.getLastCluster();
		const newCluster: IdCluster = {
			session: this,
			baseFinalId,
			baseLocalId: (lastCluster === undefined
				? -1
				: lastAllocatedLocal(lastCluster) - 1) as LocalCompressedId,
			capacity,
			count,
		};
		this.clusterChain.push(newCluster);
		return newCluster;
	}
	public isEmpty(): boolean {
		return this.clusterChain.length === 0;
	}
	public getLastCluster(): IdCluster | undefined {
		return this.clusterChain[this.clusterChain.length - 1];
	}
	public tryConvertToFinal(
		searchLocal: LocalCompressedId,
		includeAllocated: boolean,
	): FinalCompressedId | undefined {
		const containingCluster = this.getClusterByLocal(searchLocal, includeAllocated);
		if (containingCluster === undefined) {
			return undefined;
		}
		return getAlignedFinal(containingCluster, searchLocal);
	}
	public getClusterByLocal(
		localId: LocalCompressedId,
		includeAllocated: boolean,
	): IdCluster | undefined {
		const lastValidLocal: (cluster: IdCluster) => LocalCompressedId = includeAllocated
			? lastAllocatedLocal
			: lastFinalizedLocal;
		const matchedCluster = Session.binarySearch(
			localId,
			this.clusterChain,
			(local, cluster): number => {
				const lastLocal = lastValidLocal(cluster);
				if (local < lastLocal) {
					return 1;
				} else if (local > cluster.baseLocalId) {
					return -1;
				} else {
					return 0;
				}
			},
		);
		return matchedCluster;
	}
	public getClusterByAllocatedFinal(final: FinalCompressedId): IdCluster | undefined {
		return Session.getContainingCluster(final, this.clusterChain);
	}
	public static getContainingCluster(
		finalId: FinalCompressedId,
		clusterChain: readonly IdCluster[],
	): IdCluster | undefined {
		return Session.binarySearch(finalId, clusterChain, (final, cluster) => {
			const lastFinal = lastAllocatedFinal(cluster);
			if (final < cluster.baseFinalId) {
				return -1;
			} else if (final > lastFinal) {
				return 1;
			} else {
				return 0;
			}
		});
	}
	static binarySearch<S, T>(
		search: S,
		arr: readonly T[],
		comparator: (a: S, b: T) => number,
	): T | undefined {
		let left = 0;
		let right = arr.length - 1;
		while (left <= right) {
			const mid = Math.floor((left + right) / 2);
			const value = arr[mid];
			assert(value !== undefined, 0x9dc );
			const c = comparator(search, value);
			if (c === 0) {
				return value;
			} else if (c > 0) {
				left = mid + 1;
			} else {
				right = mid - 1;
			}
		}
		return undefined;
	}
	public equals(other: Session): boolean {
		for (const [index, value] of Object.entries(this.clusterChain)) {
			if (!clustersEqual(value, other.clusterChain[index] as IdCluster)) {
				return false;
			}
		}
		return this.sessionUuid === other.sessionUuid;
	}
}
export interface IdCluster {
	readonly session: Session;
	readonly baseFinalId: FinalCompressedId;
	readonly baseLocalId: LocalCompressedId;
	capacity: number;
	count: number;
}
export function clustersEqual(a: IdCluster, b: IdCluster): boolean {
	return (
		a.session.sessionUuid === b.session.sessionUuid &&
		a.baseFinalId === b.baseFinalId &&
		a.baseLocalId === b.baseLocalId &&
		a.capacity === b.capacity &&
		a.count === b.count
	);
}
export function getAlignedFinal(
	cluster: IdCluster,
	localWithin: LocalCompressedId,
): FinalCompressedId | undefined {
	const clusterOffset =
		genCountFromLocalId(localWithin) - genCountFromLocalId(cluster.baseLocalId);
	if (clusterOffset < cluster.capacity) {
		return ((cluster.baseFinalId as number) + clusterOffset) as FinalCompressedId;
	}
	return undefined;
}
export function getAlignedLocal(
	cluster: IdCluster,
	finalWithin: FinalCompressedId,
): LocalCompressedId {
	assert(
		finalWithin >= cluster.baseFinalId && finalWithin <= lastAllocatedFinal(cluster),
		0x763 ,
	);
	const finalDelta = finalWithin - cluster.baseFinalId;
	return (cluster.baseLocalId - finalDelta) as LocalCompressedId;
}
export function lastAllocatedFinal(cluster: IdCluster): FinalCompressedId {
	return ((cluster.baseFinalId as number) + (cluster.capacity - 1)) as FinalCompressedId;
}
export function lastFinalizedFinal(cluster: IdCluster): FinalCompressedId {
	return ((cluster.baseFinalId as number) + (cluster.count - 1)) as FinalCompressedId;
}
export function lastAllocatedLocal(cluster: IdCluster): LocalCompressedId {
	return ((cluster.baseLocalId as number) - (cluster.capacity - 1)) as LocalCompressedId;
}
export function lastFinalizedLocal(cluster: IdCluster): LocalCompressedId {
	return ((cluster.baseLocalId as number) - (cluster.count - 1)) as LocalCompressedId;
}
```

### finalSpace: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/finalSpace.ts:1-74`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class FinalSpace {
	private readonly clusterList: IdCluster[] = [];
	public get clusters(): readonly IdCluster[] {
		return this.clusterList;
	}
	public getLastCluster(): IdCluster | undefined {
		return this.clusterList[this.clusterList.length - 1];
	}
	public addCluster(newCluster: IdCluster): void {
		const lastCluster = this.getLastCluster();
		assert(
			lastCluster === undefined ||
				newCluster.baseFinalId === lastCluster.baseFinalId + lastCluster.capacity,
			0x753 ,
		);
		this.clusterList.push(newCluster);
	}
	public getFinalizedIdLimit(): FinalCompressedId {
		const lastCluster = this.getLastCluster();
		return lastCluster === undefined
			? (0 as FinalCompressedId)
			: (((lastFinalizedFinal(lastCluster) as number) + 1) as FinalCompressedId);
	}
	public getAllocatedIdLimit(): FinalCompressedId {
		const lastCluster = this.getLastCluster();
		return lastCluster === undefined
			? (0 as FinalCompressedId)
			: (((lastAllocatedFinal(lastCluster) as number) + 1) as FinalCompressedId);
	}
	public equals(other: FinalSpace): boolean {
		for (let i = 0; i < this.clusterList.length; i++) {
			const cluster = this.clusterList[i] as IdCluster;
			if (!clustersEqual(cluster, other.clusterList[i] as IdCluster)) {
				return false;
			}
		}
		return this.clusterList.length === other.clusterList.length;
	}
}
```

### persistanceUtilities: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/persistanceUtilities.ts:1-63`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
const halfNumeric = BigInt("0xFFFFFFFFFFFFFFFF");
const sixtyFour = BigInt(64);
export function writeNumber(buffer: Float64Array, index: number, value: number): number {
	buffer[index] = value;
	return index + 1;
}
export function writeNumericUuid(
	buffer: BigUint64Array,
	index: number,
	value: NumericUuid,
): number {
	buffer[index] = value & halfNumeric;
	buffer[index + 1] = value >> sixtyFour;
	return index + 2;
}
export function writeBoolean(buffer: Float64Array, index: number, value: boolean): number {
	return writeNumber(buffer, index, value ? 1 : 0);
}
export interface Index {
	bufferFloat: Float64Array;
	bufferUint: BigUint64Array;
	index: number;
}
export function readNumber(index: Index): number {
	const value = index.bufferFloat[index.index];
	assert(value !== undefined, 0x9d9 );
	index.index += 1;
	return value;
}
export function readNumericUuid(index: Index): NumericUuid {
	const lowerHalf = index.bufferUint[index.index];
	assert(lowerHalf !== undefined, 0x9da );
	const upperHalf = index.bufferUint[index.index + 1];
	assert(upperHalf !== undefined, 0x9db );
	const value = (upperHalf << sixtyFour) | lowerHalf;
	index.index += 2;
	return value as NumericUuid;
}
export function readBoolean(index: Index): boolean {
	return readNumber(index) === 1;
}
```

### idCompressor: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:1-1364`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
function rangeFinalizationError(expectedStart: number, actualStart: number): LoggingError {
	return new LoggingError("Ranges finalized out of order", {
		expectedStart,
		actualStart,
	});
}
const MAX_STRIDE_LENGTH = 1000000;
function validateShardGenerationCount(localGenCount: number): void {
	if (!Number.isSafeInteger(localGenCount) || localGenCount < 0) {
		throw new TypeError("Invalid shard synchronization token generation count.");
	}
}
export class IdCompressor implements IIdCompressor, IIdCompressorCore {
	private readonly eventEmitter = createEmitter<IdCompressorEvents>();
	public readonly events: Listenable<IdCompressorEvents> = this.eventEmitter;
	public static readonly maxClusterSize = 2 ** 20;
	public readonly localSessionId: SessionId;
	private readonly localSession: Session;
	private readonly normalizer = new SessionSpaceNormalizer();
	private localGenCount = 0;
	private shardingState?:
		| {
				currentStride: number;
				originalStride: number;
				activeChildIds: Set<SessionId>;
				shardId?: SessionId;
		  }
		| undefined;
	private nextRangeBaseGenCount = 1;
	private readonly sessions = new Sessions();
	private readonly finalSpace = new FinalSpace();
	private nextRequestedClusterSize: number = 512;
	private telemetryLocalIdCount = 0;
	private telemetryEagerFinalIdCount = 0;
	private ongoingGhostSession?: { cluster?: IdCluster; ghostSessionId: SessionId } | undefined;
	public constructor(
		localSessionIdOrDeserialized: SessionId | Sessions,
		private readonly logger: TelemetryLoggerExt | undefined,
		private readonly writeVersion: SerializationVersion,
	) {
		if (typeof localSessionIdOrDeserialized === "string") {
			this.localSessionId = localSessionIdOrDeserialized;
			this.localSession = this.sessions.getOrCreate(localSessionIdOrDeserialized);
		} else {
			this.sessions = localSessionIdOrDeserialized;
			const firstSession = localSessionIdOrDeserialized.sessions().next();
			assert(!firstSession.done, 0x754 );
			this.localSession = firstSession.value;
			this.localSessionId = stableIdFromNumericUuid(
				this.localSession.sessionUuid,
			) as SessionId;
		}
	}
	public generateCompressedId(): SessionSpaceCompressedId {
		if (this.ongoingGhostSession) {
			if (this.ongoingGhostSession.cluster === undefined) {
				this.ongoingGhostSession.cluster = this.addEmptyCluster(
					this.sessions.getOrCreate(this.ongoingGhostSession.ghostSessionId),
					1,
				);
			} else {
				this.ongoingGhostSession.cluster.capacity++;
			}
			this.ongoingGhostSession.cluster.count++;
			return lastFinalizedFinal(
				this.ongoingGhostSession.cluster,
			) as unknown as SessionSpaceCompressedId;
		}
		if (this.shardingState !== undefined) {
			this.telemetryLocalIdCount++;
			const { currentStride } = this.shardingState;
			this.normalizer.addLocalRange(this.localGenCount + 1, currentStride);
			this.localGenCount += currentStride;
			return localIdFromGenCount(this.localGenCount);
		}
		this.localGenCount++;
		const lastCluster = this.localSession.getLastCluster();
		if (lastCluster === undefined) {
			this.telemetryLocalIdCount++;
			return this.generateNextLocalId();
		}
		const clusterOffset = this.localGenCount - genCountFromLocalId(lastCluster.baseLocalId);
		if (lastCluster.capacity > clusterOffset) {
			this.telemetryEagerFinalIdCount++;
			return ((lastCluster.baseFinalId as number) + clusterOffset) as SessionSpaceCompressedId;
		}
		this.telemetryLocalIdCount++;
		return this.generateNextLocalId();
	}
	public generateDocumentUniqueId():
		| (SessionSpaceCompressedId & OpSpaceCompressedId)
		| StableId {
		const id = this.generateCompressedId();
		return isFinalId(id) ? id : this.decompress(id);
	}
	public startGhostSession(ghostSessionId: SessionId): void {
		assert(!this.ongoingGhostSession, 0x8fe );
		this.ongoingGhostSession = { ghostSessionId };
	}
	public beginGhostSession(ghostSessionId: SessionId, ghostSessionCallback: () => void): void {
		if (this.shardingState) {
			throw new Error("Cannot start a ghost session while sharded.");
		}
		this.startGhostSession(ghostSessionId);
		try {
			ghostSessionCallback();
		} finally {
			this.ongoingGhostSession = undefined;
		}
	}
	public shard(newShardCount: number): SerializedIdCompressorShard[] {
		if (!Number.isSafeInteger(newShardCount) || newShardCount <= 0) {
			throw new Error("Shard count must be a positive safe integer");
		}
		if (this.ongoingGhostSession) {
			throw new Error("Cannot shard during ghost session");
		}
		if (this.writeVersion < SerializationVersion.V3) {
			throw new Error(
				`Sharding requires document version ${SerializationVersion.V3} or higher, but this document is version ${this.writeVersion}`,
			);
		}
		const currentStride = this.shardingState?.currentStride ?? 1;
		const newStride = currentStride * (newShardCount + 1);
		if (newStride > MAX_STRIDE_LENGTH) {
			throw new Error("Sharding limit reached.");
		}
		assert(Number.isSafeInteger(newStride), 0xd52 );
		if (this.shardingState === undefined) {
			this.shardingState = {
				currentStride: newStride,
				originalStride: 1,
				activeChildIds: new Set(),
			};
		} else {
			this.shardingState.currentStride = newStride;
		}
		const serialized = this.serialize(true);
		const { localGenCount: parentGenCount } = this;
		const shards: SerializedIdCompressorShard[] = [];
		for (let i = 1; i <= newShardCount; i++) {
			const childShardId = createSessionId();
			this.shardingState.activeChildIds.add(childShardId);
			const childLocalGenCount = parentGenCount + i * currentStride;
			const child = deserializeIdCompressor(serialized, this.writeVersion) as IdCompressor;
			const genCountJump = childLocalGenCount - parentGenCount;
			assert(
				child.localGenCount === parentGenCount && genCountJump > 0,
				0xd53 ,
			);
			child.normalizer.addLocalRange(child.localGenCount + 1, genCountJump);
			child.localGenCount = childLocalGenCount;
			child.shardingState = {
				currentStride: newStride,
				originalStride: newStride,
				activeChildIds: new Set(),
				shardId: childShardId,
			};
			shards.push({
				serialized: child.serialize(true),
				syncToken: child.makeShardToken(false),
			});
		}
		return shards;
	}
	public synchronizeWithShard(syncToken: ShardSynchronizationToken): void {
		const isNowLeaf = this.synchronizeChild(syncToken);
		if (syncToken.disposed) {
			assert(this.shardingState !== undefined, 0xd54 );
			if (isNowLeaf && this.shardingState.originalStride === 1) {
				this.shardingState = undefined;
			}
		}
	}
	public getChildShardSyncToken(
		childToken: ShardSynchronizationToken,
	): ParentShardSynchronizationToken {
		if (!this.shardingState?.activeChildIds.has(childToken.shardId)) {
			throw new Error("Cannot get a synchronization token for an inactive child shard.");
		}
		const token: ParentShardSynchronizationToken = {
			type: "parentIdSpaceShardSyncToken",
			shardId: childToken.shardId,
			localGenCount: this.localGenCount,
		};
		return token;
	}
	public synchronizeWithParent(token: ParentShardSynchronizationToken): void {
		const state = this.shardingState;
		if (
			token.type !== "parentIdSpaceShardSyncToken" ||
			state?.shardId === undefined ||
			state.shardId !== token.shardId
		) {
			throw new Error("Invalid parent synchronization token for this child shard.");
		}
		validateShardGenerationCount(token.localGenCount);
		if (token.localGenCount <= this.localGenCount) {
			return;
		}
		this.backfillToNextStridePosition(token.localGenCount, state.currentStride);
	}
	private backfillToNextStridePosition(targetGenCount: number, stride: number): void {
		if (targetGenCount <= this.localGenCount) {
			return;
		}
		const count = Math.ceil((targetGenCount - this.localGenCount + 1) / stride) * stride;
		const nextGenCount = this.localGenCount + count;
		if (!Number.isSafeInteger(nextGenCount)) {
			throw new TypeError("Shard progress exceeds the supported ID space.");
		}
		this.normalizer.addLocalRange(this.localGenCount + 1, count);
		this.localGenCount = nextGenCount;
	}
	private synchronizeChild(syncToken: ShardToken): boolean {
		const childDisposed = syncToken.disposed;
		if (this.writeVersion < SerializationVersion.V3) {
			throw new Error(
				`Sharding requires document version ${SerializationVersion.V3} or higher, but this document is version ${this.writeVersion}`,
			);
		}
		if (this.shardingState === undefined) {
			throw new Error("Must be in sharding mode.");
		}
		const childShardId = syncToken.shardId;
		const { activeChildIds, originalStride } = this.shardingState;
		if (!activeChildIds.has(childShardId)) {
			throw new Error(
				`Cannot synchronize with child with ID ${childShardId}: not in active children set`,
			);
		}
		validateShardGenerationCount(syncToken.localGenCount);
		const isLeaf = childDisposed && activeChildIds.size === 1;
		this.backfillToNextStridePosition(
			syncToken.localGenCount,
			isLeaf ? originalStride : this.shardingState.currentStride,
		);
		if (childDisposed) {
			activeChildIds.delete(childShardId);
			if (isLeaf) {
				this.shardingState.currentStride = originalStride;
			}
		}
		return isLeaf;
	}
	public disposeShard(): ShardSynchronizationToken | undefined {
		if (this.shardingState === undefined) {
			return undefined;
		} else {
			if (this.shardingState.activeChildIds.size > 0) {
				throw new Error("Cannot dispose a shard with active children.");
			}
		}
		const token = this.makeShardToken(true);
		makeCompressorUnusable(this);
		return token;
	}
	public getShardSyncToken(): ShardSynchronizationToken | undefined {
		if (this.shardingState === undefined) {
			return undefined;
		}
		return this.makeShardToken(false);
	}
	private makeShardToken(disposed: boolean): ShardSynchronizationToken {
		assert(this.shardingState !== undefined, 0xd55 );
		if (this.shardingState.shardId === undefined) {
			throw new Error(
				"Cannot get a token for a root compressor - only shards can be disposed",
			);
		}
		const token: ShardToken = {
			localGenCount: this.localGenCount,
			shardId: this.shardingState.shardId,
			disposed,
		};
		return token as unknown as ShardSynchronizationToken;
	}
	private generateNextLocalId(): LocalCompressedId {
		this.normalizer.addLocalRange(this.localGenCount, 1);
		return localIdFromGenCount(this.localGenCount);
	}
	public takeNextCreationRange(): IdCreationRange {
		if (this.shardingState?.shardId !== undefined) {
			throw new Error("Cannot take a creation range from a non-root shard.");
		}
		assert(
			!this.ongoingGhostSession,
			0x8a6 ,
		);
		const count = this.localGenCount - (this.nextRangeBaseGenCount - 1);
		if (count === 0) {
			return {
				sessionId: this.localSessionId,
			};
		}
		const range: IdCreationRange = {
			sessionId: this.localSessionId,
			ids: {
				firstGenCount: this.nextRangeBaseGenCount,
				count,
				requestedClusterSize: this.nextRequestedClusterSize,
				localIdRanges: this.normalizer.getRangesBetween(
					this.nextRangeBaseGenCount,
					this.localGenCount,
				),
			},
		};
		return this.updateToRange(range);
	}
	public takeUnfinalizedCreationRange(): IdCreationRange {
		this.resetUnfinalizedCreationRange();
		return this.takeNextCreationRange();
	}
	public resetUnfinalizedCreationRange(): void {
		assert(
			!this.ongoingGhostSession,
			0xcec ,
		);
		const lastLocalCluster = this.localSession.getLastCluster();
		this.nextRangeBaseGenCount =
			lastLocalCluster === undefined
				? 1
				: genCountFromLocalId(
						(lastLocalCluster.baseLocalId - lastLocalCluster.count) as LocalCompressedId,
					);
	}
	private updateToRange(range: IdCreationRange): IdCreationRange {
		this.nextRangeBaseGenCount = this.localGenCount + 1;
		return IdCompressor.assertValidRange(range);
	}
	private static assertValidRange(range: IdCreationRange): IdCreationRange {
		if (range.ids === undefined) {
			return range;
		}
		const { count, requestedClusterSize } = range.ids;
		assert(count > 0, 0x755 );
		assert(requestedClusterSize > 0, 0x876 );
		assert(
			requestedClusterSize <= IdCompressor.maxClusterSize,
			0x877 ,
		);
		return range;
	}
	public finalizeCreationRange(range: IdCreationRange): void {
		assert(
			!this.ongoingGhostSession,
			0x8a7 ,
		);
		if (range.ids === undefined) {
			return;
		}
		IdCompressor.assertValidRange(range);
		const { sessionId, ids } = range;
		const { count, firstGenCount, requestedClusterSize } = ids;
		const session = this.sessions.getOrCreate(sessionId);
		const isLocal = session === this.localSession;
		const rangeBaseLocal = localIdFromGenCount(firstGenCount);
		let lastCluster = session.getLastCluster();
		if (lastCluster === undefined) {
			if (rangeBaseLocal !== -1) {
				throw rangeFinalizationError(-1, rangeBaseLocal);
			}
			lastCluster = this.addEmptyCluster(session, requestedClusterSize + count);
			if (isLocal) {
				this.logger?.sendTelemetryEvent({
					eventName: "RuntimeIdCompressor:FirstCluster",
					sessionId: this.localSessionId,
				});
			}
		}
		const remainingCapacity = lastCluster.capacity - lastCluster.count;
		if (lastCluster.baseLocalId - lastCluster.count !== rangeBaseLocal) {
			throw rangeFinalizationError(
				lastCluster.baseLocalId - lastCluster.count,
				rangeBaseLocal,
			);
		}
		if (remainingCapacity >= count) {
			lastCluster.count += count;
		} else {
			const overflow = count - remainingCapacity;
			const newClaimedFinalCount = overflow + requestedClusterSize;
			if (lastCluster === this.finalSpace.getLastCluster()) {
				lastCluster.capacity += newClaimedFinalCount;
				lastCluster.count += count;
				assert(
					!this.sessions.clusterCollides(lastCluster),
					0x756 ,
				);
				if (isLocal) {
					this.logger?.sendTelemetryEvent({
						eventName: "RuntimeIdCompressor:ClusterExpansion",
						sessionId: this.localSessionId,
						previousCapacity: lastCluster.capacity - newClaimedFinalCount,
						newCapacity: lastCluster.capacity,
						overflow,
					});
				}
			} else {
				lastCluster.count = lastCluster.capacity;
				const newCluster = this.addEmptyCluster(session, newClaimedFinalCount);
				newCluster.count += overflow;
				if (isLocal) {
					this.logger?.sendTelemetryEvent({
						eventName: "RuntimeIdCompressor:NewCluster",
						sessionId: this.localSessionId,
					});
				}
			}
		}
		if (isLocal) {
			this.logger?.sendTelemetryEvent({
				eventName: "RuntimeIdCompressor:IdCompressorStatus",
				eagerFinalIdCount: this.telemetryEagerFinalIdCount,
				localIdCount: this.telemetryLocalIdCount,
				sessionId: this.localSessionId,
			});
			this.telemetryEagerFinalIdCount = 0;
			this.telemetryLocalIdCount = 0;
		}
		assert(!session.isEmpty(), 0x757 );
		this.eventEmitter.emit("rangeFinalized", range);
	}
	private addEmptyCluster(session: Session, capacity: number): IdCluster {
		assert(
			!this.ongoingGhostSession?.cluster,
			0x8a8 ,
		);
		const newCluster = session.addNewCluster(
			this.finalSpace.getAllocatedIdLimit(),
			capacity,
			0,
		);
		assert(
			!this.sessions.clusterCollides(newCluster),
			0x758 ,
		);
		this.finalSpace.addCluster(newCluster);
		return newCluster;
	}
	public normalizeToOpSpace(id: SessionSpaceCompressedId): OpSpaceCompressedId {
		if (isFinalId(id)) {
			return id;
		} else {
			const local = id as unknown as LocalCompressedId;
			if (!this.normalizer.contains(local)) {
				throw new Error("Invalid ID to normalize.");
			}
			const finalForm = this.localSession.tryConvertToFinal(local, true);
			return finalForm === undefined
				? (local as unknown as OpSpaceCompressedId)
				: (finalForm as OpSpaceCompressedId);
		}
	}
	public tryNormalizeToSessionSpaceWithoutSession(
		id: OpSpaceCompressedId,
	): SessionSpaceCompressedId | undefined {
		if (isFinalId(id)) {
			const containingCluster = this.localSession.getClusterByAllocatedFinal(id);
			if (containingCluster === undefined) {
				if (id >= this.finalSpace.getFinalizedIdLimit()) {
					throw new Error("Unknown op space ID.");
				}
				return id as unknown as SessionSpaceCompressedId;
			} else {
				const alignedLocal = getAlignedLocal(containingCluster, id);
				if (this.normalizer.contains(alignedLocal)) {
					return alignedLocal;
				} else {
					if (genCountFromLocalId(alignedLocal) > this.localGenCount) {
						throw new Error("Unknown op space ID.");
					}
					return id as unknown as SessionSpaceCompressedId;
				}
			}
		} else {
			return undefined;
		}
	}
	public normalizeToSessionSpace(
		id: OpSpaceCompressedId,
		originSessionId: SessionId,
	): SessionSpaceCompressedId {
		const normalizedWithoutSession = this.tryNormalizeToSessionSpaceWithoutSession(id);
		if (normalizedWithoutSession === undefined) {
			const localToNormalize = id as unknown as LocalCompressedId;
			if (originSessionId === this.localSessionId) {
				if (this.normalizer.contains(localToNormalize)) {
					return localToNormalize;
				} else {
					throw new Error("Unknown op space ID.");
				}
			} else {
				const remoteSession = this.sessions.get(originSessionId);
				if (remoteSession === undefined) {
					throw new Error("No IDs have ever been finalized by the supplied session.");
				}
				const correspondingFinal = remoteSession.tryConvertToFinal(localToNormalize, false);
				if (correspondingFinal === undefined) {
					throw new Error("Unknown op space ID.");
				}
				return correspondingFinal as unknown as SessionSpaceCompressedId;
			}
		} else {
			return normalizedWithoutSession;
		}
	}
	public decompress(id: SessionSpaceCompressedId): StableId {
		if (isFinalId(id)) {
			const containingCluster = Session.getContainingCluster(id, this.finalSpace.clusters);
			if (containingCluster === undefined) {
				throw new Error("Unknown ID");
			}
			const alignedLocal = getAlignedLocal(containingCluster, id);
			const alignedGenCount = genCountFromLocalId(alignedLocal);
			const lastFinalizedGenCount = genCountFromLocalId(lastFinalizedLocal(containingCluster));
			if (alignedGenCount > lastFinalizedGenCount) {
				if (containingCluster.session === this.localSession) {
					assert(!this.normalizer.contains(alignedLocal), 0x759 );
				} else {
					throw new Error("Unknown ID");
				}
			}
			return stableIdFromNumericUuid(
				offsetNumericUuid(containingCluster.session.sessionUuid, alignedGenCount - 1),
			);
		} else {
			const localToDecompress = id as unknown as LocalCompressedId;
			if (!this.normalizer.contains(localToDecompress)) {
				throw new Error("Unknown ID");
			}
			return stableIdFromNumericUuid(
				offsetNumericUuid(
					this.localSession.sessionUuid,
					genCountFromLocalId(localToDecompress) - 1,
				),
			);
		}
	}
	public recompress(uncompressed: StableId): SessionSpaceCompressedId {
		const recompressed = this.tryRecompress(uncompressed);
		if (recompressed === undefined) {
			throw new Error("Could not recompress.");
		}
		return recompressed;
	}
	public tryRecompress(uncompressed: StableId): SessionSpaceCompressedId | undefined {
		const match = this.sessions.getContainingCluster(uncompressed);
		if (match === undefined) {
			const numericUncompressed = numericUuidFromStableId(uncompressed);
			const offset = subtractNumericUuids(numericUncompressed, this.localSession.sessionUuid);
			if (offset < Number.MAX_SAFE_INTEGER) {
				const genCountEquivalent = Number(offset) + 1;
				const localEquivalent = localIdFromGenCount(genCountEquivalent);
				if (this.normalizer.contains(localEquivalent)) {
					return localEquivalent;
				}
			}
			return undefined;
		} else {
			const [containingCluster, alignedLocal] = match;
			if (containingCluster.session === this.localSession) {
				if (this.normalizer.contains(alignedLocal)) {
					return alignedLocal;
				} else {
					assert(
						genCountFromLocalId(alignedLocal) <= this.localGenCount,
						0x75a ,
					);
					return getAlignedFinal(containingCluster, alignedLocal) as
						| SessionSpaceCompressedId
						| undefined;
				}
			} else {
				return genCountFromLocalId(alignedLocal) >= lastFinalizedLocal(containingCluster)
					? (getAlignedFinal(containingCluster, alignedLocal) as
							| SessionSpaceCompressedId
							| undefined)
					: undefined;
			}
		}
	}
	public serialize(withSession: true): SerializedIdCompressorWithOngoingSession;
	public serialize(withSession: false): SerializedIdCompressorWithNoSession;
	public serialize(hasLocalState: boolean): SerializedIdCompressor {
		assert(
			!this.ongoingGhostSession,
			0x8a9 ,
		);
		const { normalizer, finalSpace, sessions, localGenCount, logger, nextRangeBaseGenCount } =
			this;
		const sessionIndexMap = new Map<Session, number>();
		let sessionIndex = 0;
		for (const session of sessions.sessions()) {
			if (!session.isEmpty() || hasLocalState) {
				sessionIndexMap.set(session, sessionIndex);
				sessionIndex++;
			}
		}
		const sizeOfUuid = 2;
		const shardingStateSize =
			hasLocalState && this.writeVersion >= SerializationVersion.V3
				? this.shardingState === undefined
					? 1
					: 1 +
						2 +
						1 +
						this.shardingState.activeChildIds.size * sizeOfUuid +
						1 +
						(this.shardingState.shardId === undefined ? 0 : sizeOfUuid)
				: 0;
		const localStateSize = hasLocalState
			? 1 +
				1 +
				1 +
				normalizer.idRanges.size * 2 +
				shardingStateSize
			: 0;
		const totalSize =
			1 +
			1 +
			1 +
			1 +
			sessionIndexMap.size * sizeOfUuid +
			finalSpace.clusters.length * 3 +
			localStateSize;
		const serializedFloat = new Float64Array(totalSize);
		const serializedUint = new BigUint64Array(serializedFloat.buffer);
		let index = 0;
		index = writeNumber(serializedFloat, index, this.writeVersion);
		index = writeBoolean(serializedFloat, index, hasLocalState);
		index = writeNumber(serializedFloat, index, sessionIndexMap.size);
		index = writeNumber(serializedFloat, index, finalSpace.clusters.length);
		for (const [session] of sessionIndexMap.entries()) {
			index = writeNumericUuid(serializedUint, index, session.sessionUuid);
		}
		for (const cluster of finalSpace.clusters) {
			index = writeNumber(
				serializedFloat,
				index,
				sessionIndexMap.get(cluster.session) as number,
			);
			index = writeNumber(serializedFloat, index, cluster.capacity);
			index = writeNumber(serializedFloat, index, cluster.count);
		}
		if (hasLocalState) {
			index = writeNumber(serializedFloat, index, localGenCount);
			index = writeNumber(serializedFloat, index, nextRangeBaseGenCount);
			index = writeNumber(serializedFloat, index, normalizer.idRanges.size);
			for (const [leadingGenCount, count] of normalizer.idRanges.entries()) {
				index = writeNumber(serializedFloat, index, leadingGenCount);
				index = writeNumber(serializedFloat, index, count);
			}
			if (this.writeVersion >= SerializationVersion.V3) {
				index = writeBoolean(serializedFloat, index, this.shardingState !== undefined);
				if (this.shardingState !== undefined) {
					index = writeNumber(serializedFloat, index, this.shardingState.currentStride);
					index = writeNumber(serializedFloat, index, this.shardingState.originalStride);
					index = writeNumber(serializedFloat, index, this.shardingState.activeChildIds.size);
					for (const childId of this.shardingState.activeChildIds) {
						index = writeNumericUuid(serializedUint, index, numericUuidFromStableId(childId));
					}
					index = writeBoolean(
						serializedFloat,
						index,
						this.shardingState.shardId !== undefined,
					);
					if (this.shardingState.shardId !== undefined) {
						index = writeNumericUuid(
							serializedUint,
							index,
							numericUuidFromStableId(this.shardingState.shardId),
						);
					}
				}
			}
		}
		assert(index === totalSize, 0x75b );
		logger?.sendTelemetryEvent({
			eventName: "RuntimeIdCompressor:SerializedIdCompressorSize",
			size: serializedFloat.byteLength,
			clusterCount: finalSpace.clusters.length,
			sessionCount: sessionIndexMap.size,
		});
		return bufferToString(serializedFloat.buffer, "base64") as SerializedIdCompressor;
	}
	public static deserialize(
		params:
			| {
					serialized: SerializedIdCompressorWithOngoingSession;
					requestedWriteVersion: SerializationVersion;
					logger?: TelemetryLoggerExt | undefined;
					newSessionId?: never;
			  }
			| {
					serialized: SerializedIdCompressorWithNoSession;
					newSessionId: SessionId;
					requestedWriteVersion: SerializationVersion;
					logger?: TelemetryLoggerExt | undefined;
			  },
	): IdCompressor {
		const { serialized, newSessionId: sessionId, logger, requestedWriteVersion } = params;
		const buffer = stringToBuffer(serialized, "base64");
		const index: Index = {
			index: 0,
			bufferFloat: new Float64Array(buffer),
			bufferUint: new BigUint64Array(buffer),
		};
		const serializedVersion = readNumber(index) as SerializationVersion;
		const writeVersion = Math.max(
			requestedWriteVersion,
			serializedVersion,
		) as SerializationVersion;
		switch (serializedVersion) {
			case 2:
			case 3: {
				break;
			}
			default: {
				if (serializedVersion === 1) {
					throw new Error("IdCompressor version 1.0 is no longer supported.");
				}
				throw new Error("Unknown IdCompressor serialized version.");
			}
		}
		const hasLocalState = readBoolean(index);
		const sessionCount = readNumber(index);
		const clusterCount = readNumber(index);
		let sessionOffset = 0;
		const sessions: [NumericUuid, Session][] = [];
		if (hasLocalState) {
			assert(
				sessionId === undefined,
				0x75e ,
			);
		} else {
			assert(sessionId !== undefined, 0x75d );
			const localSessionNumeric = numericUuidFromStableId(sessionId);
			sessions.push([localSessionNumeric, new Session(localSessionNumeric)]);
			sessionOffset = 1;
		}
		for (let i = 0; i < sessionCount; i++) {
			const numeric = readNumericUuid(index);
			sessions.push([numeric, new Session(numeric)]);
		}
		const compressor = new IdCompressor(new Sessions(sessions), logger, writeVersion);
		let baseFinalId = 0;
		for (let i = 0; i < clusterCount; i++) {
			const sessionIndex = readNumber(index);
			const sessionArray = sessions[sessionIndex + sessionOffset];
			assert(
				sessionArray !== undefined,
				0x9d8 ,
			);
			const session = sessionArray[1];
			const capacity = readNumber(index);
			const count = readNumber(index);
			const cluster = session.addNewCluster(baseFinalId as FinalCompressedId, capacity, count);
			compressor.finalSpace.addCluster(cluster);
			baseFinalId += capacity;
		}
		if (hasLocalState) {
			compressor.localGenCount = readNumber(index);
			compressor.nextRangeBaseGenCount = readNumber(index);
			const normalizerCount = readNumber(index);
			for (let i = 0; i < normalizerCount; i++) {
				compressor.normalizer.addLocalRange(readNumber(index), readNumber(index));
			}
			if (serializedVersion >= 3) {
				const hasShardingState = readBoolean(index);
				if (hasShardingState) {
					const currentStride = readNumber(index);
					const originalStride = readNumber(index);
					const activeChildCount = readNumber(index);
					const activeChildIds = new Set<SessionId>();
					for (let i = 0; i < activeChildCount; i++) {
						const childIdNumeric = readNumericUuid(index);
						activeChildIds.add(stableIdFromNumericUuid(childIdNumeric) as SessionId);
					}
					const hasShardId = readBoolean(index);
					const shardId: SessionId | undefined = hasShardId
						? (stableIdFromNumericUuid(readNumericUuid(index)) as SessionId)
						: undefined;
					compressor.shardingState = {
						currentStride,
						originalStride,
						activeChildIds,
						...(shardId !== undefined && { shardId }),
					};
				}
			}
		}
		assert(
			index.index === index.bufferFloat.length,
			0x75f ,
		);
		return compressor;
	}
	public equals(other: IdCompressor, includeLocalState: boolean): boolean {
		if (
			includeLocalState &&
			(this.localSessionId !== other.localSessionId ||
				!this.localSession.equals(other.localSession) ||
				!this.normalizer.equals(other.normalizer) ||
				this.nextRangeBaseGenCount !== other.nextRangeBaseGenCount ||
				this.localGenCount !== other.localGenCount)
		) {
			return false;
		}
		if (includeLocalState) {
			const state = this.shardingState;
			const otherState = other.shardingState;
			if (state === undefined || otherState === undefined) {
				if (state !== otherState) {
					return false;
				}
			} else {
				if (
					state.currentStride !== otherState.currentStride ||
					state.originalStride !== otherState.originalStride ||
					state.shardId !== otherState.shardId ||
					state.activeChildIds.size !== otherState.activeChildIds.size
				) {
					return false;
				}
				for (const childId of state.activeChildIds) {
					if (!otherState.activeChildIds.has(childId)) {
						return false;
					}
				}
			}
		}
		return (
			this.sessions.equals(other.sessions, includeLocalState) &&
			this.finalSpace.equals(other.finalSpace)
		);
	}
}
export function createIdCompressor(
	writeVersion: SerializationVersion,
	logger?: ITelemetryBaseLogger,
): IIdCompressor & IIdCompressorCore;
export function createIdCompressor(
	sessionId: SessionId,
	writeVersion: SerializationVersion,
	logger?: ITelemetryBaseLogger,
): IIdCompressor & IIdCompressorCore;
export function createIdCompressor(
	sessionIdOrDocumentVersion: SessionId | SerializationVersion,
	writeVersionOrLogger?: SerializationVersion | ITelemetryBaseLogger,
	loggerOrUndefined?: ITelemetryBaseLogger,
): IIdCompressor & IIdCompressorCore {
	let localSessionId: SessionId;
	let writeVersion: SerializationVersion;
	let logger: ITelemetryBaseLogger | undefined;
	if (typeof sessionIdOrDocumentVersion === "string") {
		localSessionId = sessionIdOrDocumentVersion;
		writeVersion = writeVersionOrLogger as SerializationVersion;
		logger = loggerOrUndefined;
	} else {
		localSessionId = createSessionId();
		writeVersion = sessionIdOrDocumentVersion;
		logger = writeVersionOrLogger as ITelemetryBaseLogger | undefined;
	}
	const compressor = new IdCompressor(
		localSessionId,
		logger === undefined ? undefined : createChildLogger({ logger }),
		writeVersion,
	);
	return compressor;
}
export function deserializeIdCompressor(
	serialized: SerializedIdCompressorWithOngoingSession,
	writeVersion: SerializationVersion,
	logger?: ITelemetryLoggerExt,
): IIdCompressor & IIdCompressorCore;
export function deserializeIdCompressor(
	serialized: SerializedIdCompressorWithNoSession,
	newSessionId: SessionId,
	writeVersion: SerializationVersion,
	logger?: ITelemetryLoggerExt,
): IIdCompressor & IIdCompressorCore;
export function deserializeIdCompressor(
	serialized: SerializedIdCompressor | SerializedIdCompressorWithNoSession,
	sessionIdOrDocumentVersion: SessionId | SerializationVersion,
	writeVersionOrLogger?: SerializationVersion | ITelemetryLoggerExt,
	loggerOrUndefined?: ITelemetryLoggerExt,
): IIdCompressor & IIdCompressorCore {
	if (typeof sessionIdOrDocumentVersion === "string") {
		return IdCompressor.deserialize({
			serialized: serialized as SerializedIdCompressorWithNoSession,
			logger: extractTelemetryLoggerExt<{ PossiblyUndefined: true }>(loggerOrUndefined),
			newSessionId: sessionIdOrDocumentVersion,
			requestedWriteVersion: writeVersionOrLogger as SerializationVersion,
		});
	}
	assert(
		loggerOrUndefined === undefined,
		0xc2d ,
	);
	return IdCompressor.deserialize({
		serialized: serialized as SerializedIdCompressorWithOngoingSession,
		logger: extractTelemetryLoggerExt<{ PossiblyUndefined: true }>(
			writeVersionOrLogger as ITelemetryLoggerExt | undefined,
		),
		requestedWriteVersion: sessionIdOrDocumentVersion,
	});
}
const throwDisposed = (): never => {
	throw new Error(
		"This compressor has been disposed via disposeShard() and can no longer be used.",
	);
};
function makeCompressorUnusable(compressor: IdCompressor): void {
	const proto = Object.getPrototypeOf(compressor) as object;
	for (const key of Reflect.ownKeys(proto)) {
		if (key !== "constructor" && typeof Reflect.get(proto, key) === "function") {
			Object.defineProperty(compressor, key, {
				value: throwDisposed,
				configurable: true,
				writable: true,
			});
		}
	}
}
export function serializeIdCompressor(
	compressor: IIdCompressor,
	withSession: true,
): SerializedIdCompressorWithOngoingSession;
export function serializeIdCompressor(
	compressor: IIdCompressor,
	withSession: false,
): SerializedIdCompressorWithNoSession;
export function serializeIdCompressor(
	compressor: IIdCompressor,
	withSession: boolean,
): SerializedIdCompressorWithOngoingSession | SerializedIdCompressorWithNoSession {
	const core = toIdCompressorWithCore(compressor);
	return withSession ? core.serialize(true) : core.serialize(false);
}
export function toIdCompressorWithCore(
	compressor: IIdCompressor,
): IIdCompressor & IIdCompressorCore {
	assert(
		"serialize" in compressor,
		0xced ,
	);
	return compressor as IIdCompressor & IIdCompressorCore;
}
```



## 5. Invariants and asserts

Assertions below terminate the current operation; do not convert them into successful no-ops. Ordered contracts above retain the exact condition at each failure site.

- `0x4a3`: Expected a StableId. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/utilities.ts:43`
- `0xaaf`: Unexpected undefined code point. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/utilities.ts:102`
- `0x752`: Keys in map must be sorted.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/appendOnlySortedMap.ts:249`
- `0x9dd`: ranges[0] is undefined in SessionSpaceNormalizer.getRangesBetween. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessionSpaceNormalizer.ts:80`
- `0x952`: Expected the touched up range to contain the queried ID. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessionSpaceNormalizer.ts:90`
- `0x953`: Expected the first range to start after the queried ID. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessionSpaceNormalizer.ts:95`
- `0x9de`: lastRange is undefined in SessionSpaceNormalizer.getRangesBetween. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessionSpaceNormalizer.ts:103`
- `0x954`: Expected the touched up range to contain the queried ID. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessionSpaceNormalizer.ts:110`
- `0x955`: Expected the last range to end before the queried ID. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessionSpaceNormalizer.ts:115`
- `0x760`: Duplicate session in map.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessions.ts:60`
- `0x761`: Failed to attempt to detect collisions.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessions.ts:119`
- `0x762`: The only non-empty session must be the local session.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessions.ts:146`
- `0x9dc`: value is undefined in Session.binarySearch. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessions.ts:285`
- `0x763`: Supplied ID is not within the cluster.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/sessions.ts:378`
- `0x753`: Cluster insert to final_space is out of order.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/finalSpace.ts:37`
- `0x9d9`: value is undefined in readNumber. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/persistanceUtilities.ts:46`
- `0x9da`: lowerHalf is undefined in readNumericUuid. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/persistanceUtilities.ts:53`
- `0x9db`: upperHalf is undefined in readNumericUuid. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/persistanceUtilities.ts:55`
- `0x754`: First session must be present.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:206`
- `0x8fe`: Ghost session already in progress.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:279`
- `0xd52`: Shard stride must be a safe integer. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:315`
- `0xd53`: Child offsets incorrectly calculated.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:350`
- `0xd54`: Must be sharded. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:376`
- `0xd55`: Compressor is not sharded.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:504`
- `0x8a6`: IdCompressor should not be operated normally when in a ghost session. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:539`
- `0xcec`: IdCompressor should not be operated normally when in a ghost session. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:570`
- `0x755`: Malformed ID Range.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:592`
- `0x876`: Clusters must have a positive capacity.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:593`
- `0x877`: Clusters must not exceed max cluster size.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:596`
- `0x8a7`: IdCompressor should not be operated normally when in a ghost session. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:604`
- `0x756`: Cluster collision detected.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:652`
- `0x757`: Empty sessions should not be created.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:688`
- `0x8a8`: IdCompressor should not be operated normally when in a ghost session. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:695`
- `0x758`: Cluster collision detected.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:704`
- `0x759`: Normalizer out of sync.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:801`
- `0x75a`: Clusters out of sync.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:854`
- `0x8a9`: IdCompressor should not be operated normally when in a ghost session. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:877`
- `0x75b`: Serialized size was incorrectly calculated.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:980`
- `0x75e`: Local state should not exist in serialized form.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:1044`
- `0x75d`: Local session ID is undefined.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:1048`
- `0x9d8`: sessionArray is undefined in IdCompressor.deserialize2_0. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:1068`
- `0x75f`: Failed to read entire serialized compressor.. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:1122`
- `0xc2d`: logger would be in sessionIdOrLogger in this codepath. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:1268`
- `0xced`: Expected compressor to implement IIdCompressorCore. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:1361`

## 6. JS-semantics hazards

UUID math requires exact unsigned limbs/BigInt, while compressed numbers retain JS safe-number behavior. Do not pass numeric UUIDs through Double. Maps and Sets preserve insertion order; session zero is local only with local state, and filtered summary sessions have new indices. Version/variant validation accepts uppercase hex generally but variant position explicitly only lower-case a/b or 8/9. Negative zero compares as final (`>=0`). Reserved is not finalized. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/utilities.ts:68-196` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/identifiers.ts:44-52` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:874-1125`

## 7. Test assets to reuse

- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/appendOnlySortedMap.perf.spec.ts:1-60` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/appendOnlySortedMap.spec.ts:1-202` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/idCompressor.perf.spec.ts:1-426` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/idCompressor.spec.ts:1-1770` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/numericUuid.spec.ts:1-103` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/sessionSpaceNormalizer.spec.ts:1-94` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/sharding.fuzz.spec.ts:1-563` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/sharding.spec.ts:1-1556` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/test/snapshots/summary.spec.ts:1-162` — reuse the oracle cases and expected values under the same operation order.

## 8. Open questions

None. The ordered contracts include the source behavior even where it is surprising; they are not a redesign.
