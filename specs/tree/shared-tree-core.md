# Shared-tree-core — Fluid Framework 3.11.0

## 1. Role

Shared-tree-core maintains branch histories and translates runtime sequencing into rebased local state; owns message/history codecs, commit enrichment/resubmission and summary envelope. It is generic over change family and does not implement sequence-field CRDT itself. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:94` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:92`

## 2. Surface used by other packages

SharedTreeCore, EditManager, SharedTreeBranch, GraphCommit events, transactions, commit enricher/resubmit machine, message/edit-manager codec builders, VersionedSummarizer and Summarizable. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/index.ts:6`

## 3. Wire and persisted formats

### Version selection and registered readers

Message and edit-manager supported 3,4,6,7 and `"shared-branches|v0.2"`. Baseline3; min2.43→4; min2.80→6; min2.117→7. Shared-branches override-only. Message missing/1/2 rejected by discontinued codecs introduced in2.73; edit-manager1/2 likewise; version5 rejected by both as discontinued2.74. Parent3→SharedTreeChange3; 4→4; 6/7→5; shared-branches→4. Each change in turn chooses modular and field codec versions; the dependency matrix in index.md records these selections. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecs.ts:86` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecs.ts:71` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:538`

### Message JSON

Stable formats encode properties in order `{revision,originatorId,changeset,version,customMetadata?}`. Only commit on branch main allowed. revision encoded BEFORE change; context revision passed to changeset encoder; op decoding uses originatorId for revision/session normalization. customMetadata only written by>=7. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecV1ToV4.ts:44`

Shared-branches commit `{revision,originatorId,changeset,branchId?,version,customMetadata?}`; branch creation `{originatorId,branchId?,branchName?,version}`. No explicit type discriminator; missing changeset means branch creation; otherwise revision required. Main branch ID encodes undefined/omits property; other branch IDs op-space compressed integers using originator context when decoding. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecVSharedBranches.ts:44` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branchIdCodec.ts:14`

Custom metadata encodes `{m?:JsonObject,c?:[recursiveNodes]}` with m first, c only if nonempty. Decode absent→undefined; decode recursively, then discard entire tree when no node has defined metadata. Empty metadata object IS defined; children with no metadata are retained only when somewhere in the tree carries metadata. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/customMetadataCodec.ts:12`

### Edit-manager persisted JSON

Stable `{trunk:[sequencedCommit],branches:[[sessionId,{base,commits:[commit]}]],version}`. Commit emitted `{change,revision,sessionId,customMetadata?}`; sequenced adds `sequenceNumber` then `indexInBatch?`. SequenceId optional index denotes zero. Custom metadata only>=7. Revision and atom normalization uses EACH commit session, not summarizer's local session. Peer base revisions use peer session. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsV1toV4.ts:63` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsCommons.ts:59`

Shared-branches emission order `{main,originator,version,branches?}`; each shared branch `{trunk,peers,session?,id?,name?,author?,base?}` (encoder order); peers have stable format branch tuples. originator required to encode branch IDs/base. Branches array/map traversal order is preserved. When a peer's commits contain any schema change, omit inherited trunk schema while encoding that peer, since its schema edit may have conflicted on trunk; per-commit schema changes still supply encoding context internally. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsVSharedBranches.ts:62` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsCommons.ts:131`

### Summary layout

VersionedSummarizer emits `.metadata` blob `{version:layoutVersion}` before component payload. EditManager subtree has `String` blob; layout always2 writer, reader missing metadata/v1/v2. SharedTree core's summarizables use `indexes` subtree (literal verified in summaryTypes). Overall layout metadata separate from EditManager codec. Summarizer uses shared-object serializer for handles and UTF-8 storage load; EditManager must be empty at load. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/versionedSummarizer.ts:82` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerSummarizer.ts:34` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/summaryTypes.ts:20`


### Decision procedure: `shared-tree-core/branchIdCodec.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branchIdCodec.ts:1-29`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function encodeBranchId(
	idCompressor: IIdCompressor,
	branchId: BranchId,
): OpSpaceCompressedId | undefined {
	return branchId === "main" ? undefined : idCompressor.normalizeToOpSpace(branchId);
}
export function decodeBranchId(
	idCompressor: IIdCompressor,
	encoded: OpSpaceCompressedId | undefined,
	context: { readonly originatorId: SessionId },
): BranchId {
	return encoded === undefined
		? "main"
		: idCompressor.normalizeToSessionSpace(encoded, context.originatorId);
}
```

### Decision procedure: `shared-tree-core/customMetadataCodec.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/customMetadataCodec.ts:1-42`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function encodeCustomMetadataTree(tree: CustomMetadataTree): EncodedCustomMetadataTree {
	const encoded: Mutable<EncodedCustomMetadataTree> = {};
	if (tree.metadata !== undefined) {
		encoded.m = tree.metadata;
	}
	if (tree.children.length > 0) {
		encoded.c = tree.children.map(encodeCustomMetadataTree);
	}
	return encoded;
}
export function decodeCustomMetadataTree(
	encoded: EncodedCustomMetadataTree | undefined,
): CustomMetadataTree | undefined {
	if (encoded === undefined) {
		return undefined;
	}
	const decoded = decodeNode(encoded);
	return hasMetadata(decoded) ? decoded : undefined;
}
function decodeNode(encoded: EncodedCustomMetadataTree): CustomMetadataTree {
	return {
		metadata: encoded.m,
		children: encoded.c?.map(decodeNode) ?? [],
	};
}
function hasMetadata(node: CustomMetadataTree): boolean {
	return node.metadata !== undefined || node.children.some(hasMetadata);
}
```

### Decision procedure: `shared-tree-core/customMetadataFormat.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/customMetadataFormat.ts:1-34`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type EncodedCustomMetadataTree = Type.Static<typeof EncodedCustomMetadataTree>;
export const EncodedCustomMetadataTree = Type.Recursive((Self) =>
	Type.Object(
		{
			m: Type.Optional(
				Type.Unsafe<JsonCompatibleReadOnlyObject>(
					Type.Record(Type.String(), JsonCompatibleReadOnlySchema),
				),
			),
			c: Type.Optional(Type.Array(Self)),
		},
		{ additionalProperties: false },
	),
);
```

### Decision procedure: `shared-tree-core/editManagerCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecs.ts:1-155`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const editManagerCodecName = "EditManager";
interface EditManagerCodecOptions<TChangeset> extends ICodecOptions {
	changeCodecs: ICodecFamily<TChangeset, ChangeEncodingContext>;
	dependentChangeFormatVersion: DependentFormatVersion<EditManagerFormatVersion>;
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>;
}
export function makeEditManagerCodecBuilder<TChangeset>(): VersionDispatchingCodecBuilder<
	EditManagerCodecOptions<TChangeset>,
	SummaryData<TChangeset>,
	EditManagerEncodingContext<TChangeset>,
	EditManagerFormatVersion,
	typeof editManagerCodecName,
	EditManagerDecodingContext
> {
	const versions: CodecVersion<
		SummaryData<TChangeset>,
		EditManagerEncodingContext<TChangeset>,
		EditManagerFormatVersion,
		EditManagerCodecOptions<TChangeset>,
		EditManagerDecodingContext
	>[] = [
		makeDiscontinuedCodecAndSchema(EditManagerFormatVersion.v1, "2.73.0"),
		makeDiscontinuedCodecAndSchema(EditManagerFormatVersion.v2, "2.73.0"),
		{
			minVersionForCollab: lowestMinVersionForCollab,
			formatVersion: EditManagerFormatVersion.v3,
			codec: (options: EditManagerCodecOptions<TChangeset>) =>
				makeV1toV4andV6CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(EditManagerFormatVersion.v3),
					),
					options.revisionTagCodec,
					EditManagerFormatVersion.v3,
				),
		},
		{
			minVersionForCollab: FluidClientVersion.v2_43,
			formatVersion: EditManagerFormatVersion.v4,
			codec: (options: EditManagerCodecOptions<TChangeset>) =>
				makeV1toV4andV6CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(EditManagerFormatVersion.v4),
					),
					options.revisionTagCodec,
					EditManagerFormatVersion.v4,
				),
		},
		makeDiscontinuedCodecAndSchema(EditManagerFormatVersion.v5, "2.74.0"),
		{
			minVersionForCollab: FluidClientVersion.v2_80,
			formatVersion: EditManagerFormatVersion.v6,
			codec: (options: EditManagerCodecOptions<TChangeset>) =>
				makeV1toV4andV6CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(EditManagerFormatVersion.v6),
					),
					options.revisionTagCodec,
					EditManagerFormatVersion.v6,
				),
		},
		{
			minVersionForCollab: FluidClientVersion.v2_117,
			formatVersion: EditManagerFormatVersion.v7,
			codec: (options: EditManagerCodecOptions<TChangeset>) =>
				makeV1toV4andV6CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(EditManagerFormatVersion.v7),
					),
					options.revisionTagCodec,
					EditManagerFormatVersion.v7,
				),
		},
		{
			minVersionForCollab: undefined,
			formatVersion: EditManagerFormatVersion.vSharedBranches,
			codec: (options: EditManagerCodecOptions<TChangeset>) =>
				makeSharedBranchesCodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(
							EditManagerFormatVersion.vSharedBranches,
						),
					),
					options.revisionTagCodec,
					EditManagerFormatVersion.vSharedBranches,
				),
		},
	];
	return VersionDispatchingCodecBuilder.build(editManagerCodecName, versions);
}
export function getCodecTreeForEditManagerFormatWithChange(
	clientVersion: OldestSupportedClientVersion,
	changeFormat: CodecTree,
): CodecTree {
	const builder = makeEditManagerCodecBuilder();
	return {
		...builder.getCodecTree(clientVersion),
		children: [changeFormat],
	};
}
```

### Decision procedure: `shared-tree-core/editManagerCodecsCommons.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsCommons.ts:1-316`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface EditManagerEncodingContext<TChangeset> {
	idCompressor: IIdCompressor;
	readonly schema?: SchemaAndPolicy;
	readonly hasSchemaChange: (change: TChangeset) => boolean;
	readonly isSummary: boolean;
}
export interface EditManagerDecodingContext {
	readonly idCompressor: IIdCompressor;
	readonly isSummary: boolean;
	readonly healing?: IdentifierHealingConfig;
}
function encodeCommit<TChangeset, T extends Commit<TChangeset>>(
	changeCodec: IJsonCodec<
		TChangeset,
		JsonCompatibleReadOnly,
		JsonCompatibleReadOnly,
		ChangeEncodingContext
	>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	commit: T,
	context: ChangeEncodingContext,
	includeCustomMetadata: boolean,
): Mutable<EncodedCommit<JsonCompatibleReadOnly>> {
	const encoded: Mutable<EncodedCommit<JsonCompatibleReadOnly>> = {
		change: changeCodec.encode(commit.change, { ...context, revision: commit.revision }),
		revision: revisionTagCodec.encode(commit.revision, {
			originatorId: commit.sessionId,
			idCompressor: context.idCompressor,
			revision: undefined,
			isSummary: context.isSummary,
		}),
		sessionId: commit.sessionId,
	};
	if (includeCustomMetadata && commit.customMetadata !== undefined) {
		encoded.customMetadata = encodeCustomMetadataTree(commit.customMetadata);
	}
	return encoded;
}
function decodeCommit<TChangeset, T extends EncodedCommit<JsonCompatibleReadOnly>>(
	changeCodec: IJsonCodec<
		TChangeset,
		JsonCompatibleReadOnly,
		JsonCompatibleReadOnly,
		ChangeEncodingContext
	>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	commit: T,
	context: ChangeDecodingContext,
) {
	const revision = revisionTagCodec.decode(commit.revision, {
		originatorId: commit.sessionId,
		idCompressor: context.idCompressor,
		revision: undefined,
		isSummary: context.isSummary,
	});
	return {
		sessionId: commit.sessionId,
		revision,
		change: changeCodec.decode(commit.change, { ...context, revision }),
		customMetadata: decodeCustomMetadataTree(commit.customMetadata),
	};
}
export function encodeSharedBranch<TChangeset>(
	changeCodec: IJsonCodec<
		TChangeset,
		JsonCompatibleReadOnly,
		JsonCompatibleReadOnly,
		ChangeEncodingContext
	>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	data: SharedBranchSummaryData<TChangeset>,
	context: EditManagerEncodingContext<TChangeset>,
	originatorId: SessionId | undefined,
	includeCustomMetadata: boolean,
): EncodedSharedBranch<JsonCompatibleReadOnly> {
	const json: Mutable<EncodedSharedBranch<JsonCompatibleReadOnly>> = {
		trunk: data.trunk.map((commit) => {
			const encoded = encodeCommit(
				changeCodec,
				revisionTagCodec,
				commit,
				{
					originatorId: commit.sessionId,
					idCompressor: context.idCompressor,
					schema: context.schema,
					revision: undefined,
					isSummary: context.isSummary,
				},
				includeCustomMetadata,
			);
			copyProperty(commit, "sequenceNumber", encoded);
			copyProperty(commit, "indexInBatch", encoded);
			return encoded;
		}),
		peers: Array.from(data.peerLocalBranches.entries(), ([sessionId, branch]) => {
			const schema = branch.commits.some((commit) => context.hasSchemaChange(commit.change))
				? undefined
				: context.schema;
			return [
				sessionId,
				{
					base: revisionTagCodec.encode(branch.base, {
						originatorId: sessionId,
						idCompressor: context.idCompressor,
						revision: undefined,
						isSummary: context.isSummary,
					}),
					commits: branch.commits.map((commit) =>
						encodeCommit(
							changeCodec,
							revisionTagCodec,
							commit,
							{
								originatorId: commit.sessionId,
								idCompressor: context.idCompressor,
								schema,
								revision: undefined,
								isSummary: context.isSummary,
							},
							includeCustomMetadata,
						),
					),
				},
			];
		}),
	};
	if (data.session !== undefined) {
		json.session = data.session;
	}
	if (data.id !== undefined) {
		json.id = encodeBranchId(context.idCompressor, data.id);
	}
	if (data.name !== undefined) {
		json.name = data.name;
	}
	if (data.author !== undefined) {
		json.author = data.author;
	}
	if (data.base !== undefined) {
		assert(
			originatorId !== undefined,
			0xc62  ,
		);
		json.base = revisionTagCodec.encode(data.base, {
			originatorId,
			idCompressor: context.idCompressor,
			revision: undefined,
			isSummary: context.isSummary,
		});
	}
	return json;
}
export function decodeSharedBranch<TChangeset>(
	changeCodec: IJsonCodec<
		TChangeset,
		JsonCompatibleReadOnly,
		JsonCompatibleReadOnly,
		ChangeEncodingContext
	>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	json: EncodedSharedBranch<TChangeset>,
	context: EditManagerDecodingContext,
	originatorId: SessionId | undefined,
): SharedBranchSummaryData<TChangeset> {
	const trunk = json.trunk as readonly (EncodedCommit<JsonCompatibleReadOnly> & SequenceId)[];
	const data: Mutable<SharedBranchSummaryData<TChangeset>> = {
		trunk: trunk.map((commit): SequencedCommit<TChangeset> => {
			const decoded = decodeCommit(changeCodec, revisionTagCodec, commit, {
				originatorId: commit.sessionId,
				idCompressor: context.idCompressor,
				revision: undefined,
				isSummary: context.isSummary,
				healing: context.healing,
			});
			copyProperty(commit, "sequenceNumber", decoded);
			copyProperty(commit, "indexInBatch", decoded);
			return decoded;
		}),
		peerLocalBranches: new Map(
			mapIterable(json.peers, ([sessionId, branch]) => [
				sessionId,
				{
					base: revisionTagCodec.decode(branch.base, {
						originatorId: sessionId,
						idCompressor: context.idCompressor,
						revision: undefined,
						isSummary: context.isSummary,
					}),
					commits: branch.commits.map((commit) =>
						decodeCommit(
							changeCodec,
							revisionTagCodec,
							commit as EncodedCommit<JsonCompatibleReadOnly>,
							{
								originatorId: commit.sessionId,
								idCompressor: context.idCompressor,
								revision: undefined,
								isSummary: context.isSummary,
								healing: context.healing,
							},
						),
					),
				},
			]),
		),
	};
	if (json.session !== undefined) {
		data.session = json.session;
	}
	if (json.name !== undefined) {
		data.name = json.name;
	}
	if (json.author !== undefined) {
		data.author = json.author;
	}
	if (json.id !== undefined) {
		assert(
			originatorId !== undefined,
			0xc63  ,
		);
		data.id = decodeBranchId(context.idCompressor, json.id, { originatorId });
	}
	if (json.base !== undefined) {
		assert(
			originatorId !== undefined,
			0xc64  ,
		);
		data.base = revisionTagCodec.decode(json.base, {
			originatorId,
			idCompressor: context.idCompressor,
			revision: undefined,
			isSummary: context.isSummary,
		});
	}
	return data;
}
```

### Decision procedure: `shared-tree-core/editManagerCodecsV1toV4.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsV1toV4.ts:1-103`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeV1toV4andV6CodecWithVersion<TChangeset>(
	changeCodec: IJsonCodec<
		TChangeset,
		JsonCompatibleReadOnly,
		JsonCompatibleReadOnly,
		ChangeEncodingContext
	>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	version: EncodedEditManager<TChangeset>["version"],
): CodecAndSchema<
	SummaryData<TChangeset>,
	EditManagerEncodingContext<TChangeset>,
	EditManagerDecodingContext
> {
	const includeCustomMetadata = version >= EditManagerFormatVersion.v7;
	const schema = EncodedEditManager(
		changeCodec.encodedSchema ?? JsonCompatibleReadOnlySchema,
		includeCustomMetadata,
	);
	const codec: CodecAndSchema<
		SummaryData<TChangeset>,
		EditManagerEncodingContext<TChangeset>,
		EditManagerDecodingContext
	> = {
		schema,
		encode: (
			data: SummaryData<TChangeset>,
			context: EditManagerEncodingContext<TChangeset>,
		): EncodedEditManager<TChangeset> & Versioned & JsonCompatibleReadOnlyObject => {
			const mainBranch = encodeSharedBranch(
				changeCodec,
				revisionTagCodec,
				data.main,
				context,
				data.originator,
				includeCustomMetadata,
			);
			const encoded: EncodedEditManager<JsonCompatibleReadOnly> = {
				trunk: mainBranch.trunk,
				branches: mainBranch.peers,
				version,
			};
			return encoded as EncodedEditManager<TChangeset> &
				Versioned &
				JsonCompatibleReadOnlyObject;
		},
		decode: (
			json: EncodedEditManager<TChangeset> & JsonCompatibleReadOnly,
			context: EditManagerDecodingContext,
		): SummaryData<TChangeset> => {
			return {
				main: decodeSharedBranch(
					changeCodec,
					revisionTagCodec,
					{
						trunk: json.trunk,
						peers: json.branches,
					},
					context,
					undefined,
				),
			};
		},
	};
	return codec;
}
```

### Decision procedure: `shared-tree-core/editManagerCodecsVSharedBranches.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsVSharedBranches.ts:1-133`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeSharedBranchesCodecWithVersion<TChangeset>(
	changeCodec: IJsonCodec<
		TChangeset,
		JsonCompatibleReadOnly,
		JsonCompatibleReadOnly,
		ChangeEncodingContext
	>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	version: EncodedEditManager<TChangeset>["version"],
): CodecAndSchema<
	SummaryData<TChangeset>,
	EditManagerEncodingContext<TChangeset>,
	EditManagerDecodingContext
> {
	const schema = EncodedEditManager(changeCodec.encodedSchema ?? JsonCompatibleReadOnlySchema);
	const codec: CodecAndSchema<
		SummaryData<TChangeset>,
		EditManagerEncodingContext<TChangeset>,
		EditManagerDecodingContext
	> = {
		schema,
		encode: (
			data: SummaryData<TChangeset>,
			context: EditManagerEncodingContext<TChangeset>,
		) => {
			const mainBranch = encodeSharedBranch(
				changeCodec,
				revisionTagCodec,
				data.main,
				context,
				data.originator,
				true,
			);
			assert(
				data.originator !== undefined,
				0xca5  ,
			);
			const json: Mutable<EncodedEditManager<JsonCompatibleReadOnly>> = {
				main: mainBranch,
				originator: data.originator,
				version,
			};
			if (data.branches !== undefined && data.branches.size > 0) {
				const branches: EncodedSharedBranch<JsonCompatibleReadOnly>[] = [];
				for (const [_, branch] of data.branches) {
					branches.push(
						encodeSharedBranch(
							changeCodec,
							revisionTagCodec,
							branch,
							context,
							data.originator,
							true,
						),
					);
				}
				json.branches = branches;
			}
			return json as EncodedEditManager<TChangeset> & JsonCompatibleReadOnlyObject;
		},
		decode: (
			json: EncodedEditManager<TChangeset> & JsonCompatibleReadOnlyObject,
			context: EditManagerDecodingContext,
		): SummaryData<TChangeset> => {
			const mainBranch = decodeSharedBranch(
				changeCodec,
				revisionTagCodec,
				json.main,
				context,
				json.originator,
			);
			const decoded: Mutable<SummaryData<TChangeset>> = {
				main: mainBranch,
				originator: json.originator,
			};
			if (json.branches !== undefined) {
				const branches = new Map<BranchId, SharedBranchSummaryData<TChangeset>>();
				for (const branch of json.branches) {
					const decodedBranch = decodeSharedBranch(
						changeCodec,
						revisionTagCodec,
						branch,
						context,
						json.originator,
					);
					assert(decodedBranch.id !== undefined, 0xc66  );
					assert(!branches.has(decodedBranch.id), 0xc67  );
					branches.set(decodedBranch.id, decodedBranch);
				}
				decoded.branches = branches;
			}
			return decoded;
		},
	};
	return codec;
}
```

### Decision procedure: `shared-tree-core/editManagerFormatCommons.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerFormatCommons.ts:1-217`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface Commit<TChangeset> {
	readonly revision: RevisionTag;
	readonly change: TChangeset;
	readonly sessionId: SessionId;
	readonly customMetadata: CustomMetadataTree | undefined;
}
export type EncodedCommit<TChangeset> = {
	readonly revision: EncodedRevisionTag;
	readonly change: TChangeset;
	readonly sessionId: SessionId;
	readonly customMetadata?: EncodedCustomMetadataTree;
};
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
const CommitBase = <ChangeSchema extends TSchema>(
	tChange: ChangeSchema,
	includeCustomMetadata: boolean,
) =>
	Type.Object({
		revision: RevisionTagSchema,
		change: tChange,
		sessionId: SessionIdSchema,
		...(includeCustomMetadata
			? { customMetadata: Type.Optional(EncodedCustomMetadataTree) }
			: {}),
	});
const Commit = <ChangeSchema extends TSchema>(
	tChange: ChangeSchema,
	includeCustomMetadata: boolean,
) => Type.Composite([CommitBase(tChange, includeCustomMetadata)], noAdditionalProps);
export type SeqNumber = Brand<number, "edit-manager.SeqNumber">;
const SeqNumber = brandedIntegerType<SeqNumber>();
const SequenceId = Type.Object({
	sequenceNumber: SeqNumber,
	indexInBatch: Type.Optional(Type.Integer({ minimum: 0 })),
});
export type SequenceId = Static<typeof SequenceId>;
export interface SequencedCommit<TChangeset> extends Commit<TChangeset>, SequenceId {}
export type EncodedSequencedCommit<TChangeset> = EncodedCommit<TChangeset> & SequenceId;
export const SequencedCommit = <ChangeSchema extends TSchema>(
	tChange: ChangeSchema,
	includeCustomMetadata: boolean,
) =>
	Type.Composite([CommitBase(tChange, includeCustomMetadata), SequenceId], noAdditionalProps);
export interface SummarySessionBranch<TChangeset> {
	readonly base: RevisionTag;
	readonly commits: Commit<TChangeset>[];
}
export interface EncodedSummarySessionBranch<TChangeset> {
	readonly base: EncodedRevisionTag;
	readonly commits: EncodedCommit<TChangeset>[];
}
export const SummarySessionBranch = <ChangeSchema extends TSchema>(
	tChange: ChangeSchema,
	includeCustomMetadata: boolean,
) =>
	Type.Object(
		{
			base: RevisionTagSchema,
			commits: Type.Array(Commit(tChange, includeCustomMetadata)),
		},
		noAdditionalProps,
	);
export interface EncodedSharedBranch<TChangeset> {
	readonly id?: EncodedBranchId;
	readonly name?: string;
	readonly author?: string;
	readonly session?: SessionId;
	readonly base?: EncodedRevisionTag;
	readonly trunk: readonly Readonly<EncodedSequencedCommit<TChangeset>>[];
	readonly peers: readonly [SessionId, Readonly<EncodedSummarySessionBranch<TChangeset>>][];
}
export const EncodedSharedBranch = <ChangeSchema extends TSchema>(
	tChange: ChangeSchema,
	includeCustomMetadata: boolean,
) =>
	Type.Object(
		{
			id: Type.Optional(Type.Number()),
			name: Type.Optional(Type.String()),
			session: Type.Optional(SessionIdSchema),
			author: Type.Optional(Type.String()),
			base: Type.Optional(RevisionTagSchema),
			trunk: Type.Array(SequencedCommit(tChange, includeCustomMetadata)),
			peers: Type.Array(
				Type.Tuple([SessionIdSchema, SummarySessionBranch(tChange, includeCustomMetadata)]),
			),
		},
		noAdditionalProps,
	);
export const EditManagerFormatVersion = strictEnum("editManager.FormatVersion", {
	v1: 1,
	v2: 2,
	v3: 3,
	v4: 4,
	v5: 5,
	v6: 6,
	v7: 7,
	vSharedBranches: "shared-branches|v0.2",
});
export type EditManagerFormatVersion = Values<typeof EditManagerFormatVersion>;
export const supportedEditManagerFormatVersions: ReadonlySet<EditManagerFormatVersion> =
	new Set([
		EditManagerFormatVersion.v3,
		EditManagerFormatVersion.v4,
		EditManagerFormatVersion.v6,
		EditManagerFormatVersion.v7,
		EditManagerFormatVersion.vSharedBranches,
	]);
export const editManagerFormatVersions: ReadonlySet<EditManagerFormatVersion> = new Set(
	Object.values(EditManagerFormatVersion),
);
```

### Decision procedure: `shared-tree-core/editManagerFormatV1toV4.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerFormatV1toV4.ts:1-59`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export interface EncodedEditManager<TChangeset> {
	readonly trunk: readonly Readonly<EncodedSequencedCommit<TChangeset>>[];
	readonly branches: readonly [SessionId, Readonly<EncodedSummarySessionBranch<TChangeset>>][];
	readonly version:
		| typeof EditManagerFormatVersion.v1
		| typeof EditManagerFormatVersion.v2
		| typeof EditManagerFormatVersion.v3
		| typeof EditManagerFormatVersion.v4
		| typeof EditManagerFormatVersion.v6
		| typeof EditManagerFormatVersion.v7;
}
export const EncodedEditManager = <ChangeSchema extends TSchema>(
	tChange: ChangeSchema,
	includeCustomMetadata: boolean,
) =>
	Type.Object(
		{
			version: Type.Union([
				Type.Literal(EditManagerFormatVersion.v1),
				Type.Literal(EditManagerFormatVersion.v2),
				Type.Literal(EditManagerFormatVersion.v3),
				Type.Literal(EditManagerFormatVersion.v4),
				Type.Literal(EditManagerFormatVersion.v6),
				Type.Literal(EditManagerFormatVersion.v7),
			]),
			trunk: Type.Array(SequencedCommit(tChange, includeCustomMetadata)),
			branches: Type.Array(
				Type.Tuple([SessionIdSchema, SummarySessionBranch(tChange, includeCustomMetadata)]),
			),
		},
		noAdditionalProps,
	);
```

### Decision procedure: `shared-tree-core/editManagerFormatVSharedBranches.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerFormatVSharedBranches.ts:1-37`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export interface EncodedEditManager<TChangeset> {
	readonly version: typeof EditManagerFormatVersion.vSharedBranches;
	readonly originator: SessionId;
	readonly main: EncodedSharedBranch<TChangeset>;
	readonly branches?: readonly EncodedSharedBranch<TChangeset>[];
}
export const EncodedEditManager = <ChangeSchema extends TSchema>(tChange: ChangeSchema) =>
	Type.Object(
		{
			version: Type.Literal(EditManagerFormatVersion.vSharedBranches),
			originator: SessionIdSchema,
			main: EncodedSharedBranch(tChange, true),
			branches: Type.Optional(Type.Array(EncodedSharedBranch(tChange, true))),
		},
		noAdditionalProps,
	);
```

### Decision procedure: `shared-tree-core/messageCodecV1ToV4.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecV1ToV4.ts:1-113`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeV1ToV4CodecWithVersion<TChangeset>(
	changeCodec: ChangeFamilyCodec<TChangeset>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	version:
		| typeof MessageFormatVersion.v1
		| typeof MessageFormatVersion.v2
		| typeof MessageFormatVersion.v3
		| typeof MessageFormatVersion.v4
		| typeof MessageFormatVersion.v6
		| typeof MessageFormatVersion.v7,
): CodecAndSchema<DecodedMessage<TChangeset>, MessageEncodingContext, MessageDecodingContext> {
	const supportsCustomMetadata = version >= MessageFormatVersion.v7;
	const schema = Message(
		changeCodec.encodedSchema ?? JsonCompatibleReadOnlySchema,
		supportsCustomMetadata,
	);
	return {
		schema,
		encode: (
			decoded: DecodedMessage<TChangeset>,
			context: MessageEncodingContext,
		): Message & JsonCompatibleReadOnlyObject & Versioned => {
			assert(decoded.type === "commit", 0xc68  );
			assert(
				decoded.branchId === "main",
				0xc69  ,
			);
			const { commit, sessionId: originatorId } = decoded;
			const encoded: Mutable<Message & JsonCompatibleReadOnlyObject & Versioned> = {
				revision: revisionTagCodec.encode(commit.revision, {
					originatorId,
					idCompressor: context.idCompressor,
					revision: undefined,
					isSummary: false,
				}),
				originatorId,
				changeset: changeCodec.encode(commit.change, {
					originatorId,
					schema: context.schema,
					idCompressor: context.idCompressor,
					revision: commit.revision,
					isSummary: false,
				}),
				version,
			};
			if (supportsCustomMetadata && commit.customMetadata !== undefined) {
				encoded.customMetadata = encodeCustomMetadataTree(commit.customMetadata);
			}
			return encoded;
		},
		decode: (
			encoded: Message & JsonCompatibleReadOnlyObject & Versioned,
			context: MessageDecodingContext,
		): DecodedMessage<TChangeset> => {
			const { revision: encodedRevision, originatorId, changeset, customMetadata } = encoded;
			const revision = revisionTagCodec.decode(encodedRevision, {
				originatorId,
				revision: undefined,
				idCompressor: context.idCompressor,
				isSummary: false,
			});
			return {
				branchId: "main",
				type: "commit",
				commit: {
					revision,
					change: changeCodec.decode(changeset, {
						originatorId,
						revision,
						idCompressor: context.idCompressor,
						isSummary: false,
					}),
					customMetadata: decodeCustomMetadataTree(customMetadata),
				},
				sessionId: originatorId,
			};
		},
	};
}
```

### Decision procedure: `shared-tree-core/messageCodecVSharedBranches.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecVSharedBranches.ts:1-136`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeSharedBranchesCodecWithVersion<TChangeset>(
	changeCodec: ChangeFamilyCodec<TChangeset>,
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	version: typeof MessageFormatVersion.vSharedBranches,
): CodecAndSchema<DecodedMessage<TChangeset>, MessageEncodingContext> {
	const schema: TAnySchema = Message(changeCodec.encodedSchema ?? Type.Any());
	return {
		schema,
		encode: (
			message: DecodedMessage<TChangeset>,
			context: MessageEncodingContext,
		): Message & JsonCompatibleReadOnlyObject & Versioned => {
			const type = message.type;
			switch (type) {
				case "commit": {
					const changeContext: ChangeEncodingContext = {
						originatorId: message.sessionId,
						schema: context.schema,
						idCompressor: context.idCompressor,
						revision: message.commit.revision,
						isSummary: false,
					};
					const encoded: Mutable<Message & JsonCompatibleReadOnlyObject & Versioned> = {
						revision: revisionTagCodec.encode(message.commit.revision, {
							originatorId: message.sessionId,
							idCompressor: context.idCompressor,
							revision: undefined,
							isSummary: false,
						}),
						originatorId: message.sessionId,
						changeset: changeCodec.encode(message.commit.change, changeContext),
						branchId: encodeBranchId(context.idCompressor, message.branchId),
						version,
					};
					if (message.commit.customMetadata !== undefined) {
						encoded.customMetadata = encodeCustomMetadataTree(message.commit.customMetadata);
					}
					return encoded;
				}
				case "branch": {
					return {
						originatorId: message.sessionId,
						branchId: encodeBranchId(context.idCompressor, message.branchId),
						branchName: message.branchName,
						version,
					};
				}
				default: {
					unreachableCase(type);
				}
			}
		},
		decode: (
			encoded: Message & JsonCompatibleReadOnlyObject & Versioned,
			context: MessageDecodingContext,
		): DecodedMessage<TChangeset> => {
			const {
				revision: encodedRevision,
				originatorId,
				changeset,
				branchId: encodedBranchId,
				branchName: encodedBranchName,
				customMetadata,
			} = encoded;
			const changeContext: ChangeEncodingContext = {
				originatorId,
				revision: undefined,
				idCompressor: context.idCompressor,
				isSummary: false,
			};
			const branchId = decodeBranchId(context.idCompressor, encodedBranchId, changeContext);
			if (changeset === undefined) {
				return {
					type: "branch",
					sessionId: originatorId,
					branchId,
					branchName: encodedBranchName,
				};
			}
			assert(encodedRevision !== undefined, 0xc6a  );
			const revision = revisionTagCodec.decode(encodedRevision, changeContext);
			return {
				type: "commit",
				commit: {
					revision,
					change: changeCodec.decode(changeset, {
						originatorId,
						revision,
						idCompressor: context.idCompressor,
						isSummary: false,
					}),
					customMetadata: decodeCustomMetadataTree(customMetadata),
				},
				branchId,
				sessionId: originatorId,
			};
		},
	};
}
```

### Decision procedure: `shared-tree-core/messageCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecs.ts:1-166`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface MessageEncodingContext {
	idCompressor: IIdCompressor;
	schema?: SchemaAndPolicy;
}
export interface MessageDecodingContext {
	idCompressor: IIdCompressor;
}
export const messageCodecName = "Message";
interface MessageCodecBuilderOptions<TChangeset> extends ICodecOptions {
	changeCodecs: ICodecFamily<TChangeset, ChangeEncodingContext>;
	dependentChangeFormatVersion: DependentFormatVersion<MessageFormatVersion>;
	revisionTagCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>;
}
export function makeMessageCodecBuilder<TChangeset>(): VersionDispatchingCodecBuilder<
	MessageCodecBuilderOptions<TChangeset>,
	DecodedMessage<TChangeset>,
	MessageEncodingContext,
	MessageFormatVersion | undefined,
	typeof messageCodecName,
	MessageDecodingContext
> {
	const versions: CodecVersion<
		DecodedMessage<TChangeset>,
		MessageEncodingContext,
		MessageFormatVersion | undefined,
		MessageCodecBuilderOptions<TChangeset>,
		MessageDecodingContext
	>[] = [
		makeDiscontinuedCodecAndSchema(undefined, "2.73.0"),
		makeDiscontinuedCodecAndSchema(MessageFormatVersion.v1, "2.73.0"),
		makeDiscontinuedCodecAndSchema(MessageFormatVersion.v2, "2.73.0"),
		{
			minVersionForCollab: lowestMinVersionForCollab,
			formatVersion: MessageFormatVersion.v3,
			codec: (options: MessageCodecBuilderOptions<TChangeset>) =>
				makeV1ToV4CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(MessageFormatVersion.v3),
					),
					options.revisionTagCodec,
					MessageFormatVersion.v3,
				),
		},
		{
			minVersionForCollab: FluidClientVersion.v2_43,
			formatVersion: MessageFormatVersion.v4,
			codec: (options: MessageCodecBuilderOptions<TChangeset>) =>
				makeV1ToV4CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(MessageFormatVersion.v4),
					),
					options.revisionTagCodec,
					MessageFormatVersion.v4,
				),
		},
		makeDiscontinuedCodecAndSchema(MessageFormatVersion.v5, "2.74.0"),
		{
			minVersionForCollab: FluidClientVersion.v2_80,
			formatVersion: MessageFormatVersion.v6,
			codec: (options: MessageCodecBuilderOptions<TChangeset>) =>
				makeV1ToV4CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(MessageFormatVersion.v6),
					),
					options.revisionTagCodec,
					MessageFormatVersion.v6,
				),
		},
		{
			minVersionForCollab: FluidClientVersion.v2_117,
			formatVersion: MessageFormatVersion.v7,
			codec: (options: MessageCodecBuilderOptions<TChangeset>) =>
				makeV1ToV4CodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(MessageFormatVersion.v7),
					),
					options.revisionTagCodec,
					MessageFormatVersion.v7,
				),
		},
		{
			minVersionForCollab: undefined,
			formatVersion: MessageFormatVersion.vSharedBranches,
			codec: (options: MessageCodecBuilderOptions<TChangeset>) =>
				makeSharedBranchesCodecWithVersion(
					options.changeCodecs.resolve(
						options.dependentChangeFormatVersion.lookup(MessageFormatVersion.vSharedBranches),
					),
					options.revisionTagCodec,
					MessageFormatVersion.vSharedBranches,
				),
		},
	];
	return VersionDispatchingCodecBuilder.build(messageCodecName, versions);
}
export function getCodecTreeForMessageFormatWithChange(
	clientVersion: OldestSupportedClientVersion,
	changeFormat: CodecTree,
): CodecTree {
	const builder = makeMessageCodecBuilder();
	return {
		...builder.getCodecTree(clientVersion),
		children: [changeFormat],
	};
}
```

### Decision procedure: `shared-tree-core/messageFormat.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageFormat.ts:1-73`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const MessageFormatVersion = strictEnum("MessageFormatVersion", {
	undefined: 0,
	v1: 1,
	v2: 2,
	v3: 3,
	v4: 4,
	v5: 5,
	v6: 6,
	v7: 7,
	vSharedBranches: "shared-branches|v0.2",
});
export type MessageFormatVersion = Values<typeof MessageFormatVersion>;
export const supportedMessageFormatVersions: ReadonlySet<MessageFormatVersion> = new Set([
	MessageFormatVersion.v3,
	MessageFormatVersion.v4,
	MessageFormatVersion.v6,
	MessageFormatVersion.v7,
	MessageFormatVersion.vSharedBranches,
]);
```

### Decision procedure: `shared-tree-core/messageFormatV1ToV4.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageFormatV1ToV4.ts:1-80`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface Message {
	readonly revision: EncodedRevisionTag;
	readonly originatorId: SessionId;
	readonly changeset: JsonCompatibleReadOnly;
	readonly customMetadata?: EncodedCustomMetadataTree;
	readonly version?:
		| typeof MessageFormatVersion.v1
		| typeof MessageFormatVersion.v2
		| typeof MessageFormatVersion.v3
		| typeof MessageFormatVersion.v4
		| typeof MessageFormatVersion.v6
		| typeof MessageFormatVersion.v7;
}
export const Message = <ChangeSchema extends TSchema>(
	tChange: ChangeSchema,
	includeCustomMetadata: boolean,
) =>
	Type.Object({
		revision: RevisionTagSchema,
		originatorId: SessionIdSchema,
		changeset: tChange,
		...(includeCustomMetadata
			? { customMetadata: Type.Optional(EncodedCustomMetadataTree) }
			: {}),
		version: Type.Optional(
			Type.Union([
				Type.Literal(MessageFormatVersion.v1),
				Type.Literal(MessageFormatVersion.v2),
				Type.Literal(MessageFormatVersion.v3),
				Type.Literal(MessageFormatVersion.v4),
				Type.Literal(MessageFormatVersion.v6),
				Type.Literal(MessageFormatVersion.v7),
			]),
		),
	});
```

### Decision procedure: `shared-tree-core/messageFormatVSharedBranches.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageFormatVSharedBranches.ts:1-68`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface Message {
	readonly revision?: EncodedRevisionTag;
	readonly originatorId: SessionId;
	readonly changeset?: JsonCompatibleReadOnly;
	readonly branchId?: EncodedBranchId;
	readonly branchName?: string;
	readonly customMetadata?: EncodedCustomMetadataTree;
	readonly version: typeof MessageFormatVersion.vSharedBranches;
}
export const Message = <ChangeSchema extends TSchema>(tChange: ChangeSchema) =>
	Type.Object({
		revision: Type.Optional(RevisionTagSchema),
		originatorId: SessionIdSchema,
		changeset: Type.Optional(tChange),
		branchId: Type.Optional(Type.Number()),
		branchName: Type.Optional(Type.String()),
		customMetadata: Type.Optional(EncodedCustomMetadataTree),
		version: Type.Literal(MessageFormatVersion.vSharedBranches),
	});
```

### Decision procedure: `shared-tree-core/summaryTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/summaryTypes.ts:1-122`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const summarizablesTreeKey = "indexes";
export const summarizablesMetadataKey = ".metadata";
export interface Summarizable {
	readonly key: string;
	summarize(props: {
		stringify: SummaryElementStringifier;
		fullTree?: boolean;
		trackState?: boolean;
		telemetryContext?: ITelemetryContext;
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext;
	}): ISummaryTreeWithStats;
	load(service: IChannelStorageService, parse: SummaryElementParser): Promise<void>;
}
export type SummaryElementStringifier = (contents: unknown) => string;
export type SummaryElementParser = (contents: string) => unknown;
export type SharedTreeSummarizableMetadata = {
	readonly version: number;
};
export const enum SharedTreeSummaryFormatVersion {
	v1 = 1,
	v2 = 2,
	vLatest = v2,
}
export const supportedSharedTreeSummaryFormatVersions =
	new Set<SharedTreeSummaryFormatVersion>([
		SharedTreeSummaryFormatVersion.v1,
		SharedTreeSummaryFormatVersion.v2,
	]);
export function minVersionToSharedTreeSummaryFormatVersion(
	version: OldestSupportedClientVersion,
): SharedTreeSummaryFormatVersion {
	return SharedTreeSummaryFormatVersion.v2;
}
```

### Literal message, history and metadata examples

With an empty SharedTree change union (`changes:[]` in memory), a main-branch message for op-space revision 0 from session `00000000-0000-4000-8000-000000000001` emits `{"revision":0,"originatorId":"00000000-0000-4000-8000-000000000001","changeset":[],"version":3}`. Stable versions 4, 6 and 7 produce the same empty payload with their version number. V7 application metadata `{}` adds `"customMetadata":{"m":{}}` after version; before v7 it is omitted. Empty metadata does not mean absent metadata. The change union's [] result follows its encoder's empty loop. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecV1ToV4.ts:44-113` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeCodecs.ts:184-216`

Empty EditManager summary emits `{"trunk":[],"branches":[],"version":3}` (likewise 4, 6, 7). A one-commit trunk emits `{"trunk":[{"change":[],"revision":0,"sessionId":"00000000-0000-4000-8000-000000000001","sequenceNumber":1}],"branches":[],"version":7}`; `indexInBatch` is absent for first commit, and a following commit of the same runtime batch has indexInBatch 1. Note change-before-revision in this encoder, unlike messages. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsCommons.ts:59-177` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsV1toV4.ts:63-103`

Shared-branches empty history emits `{"main":{"trunk":[],"peers":[]},"originator":"00000000-0000-4000-8000-000000000001","version":"shared-branches|v0.2"}`; the empty branches collection is omitted. A create-main message emits `{"originatorId":"00000000-0000-4000-8000-000000000001","version":"shared-branches|v0.2"}`; a nonmain create additionally inserts branchId and optional branchName before version. The codec has no separate type string. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsVSharedBranches.ts:62-133` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecVSharedBranches.ts:44-136`

EditManager layout example: `.metadata` blob `{"version":2}` then `String` blob holding one of the history objects above. This subtree is under `indexes/EditManager`, independent of Forest, Schema and DetachedFieldIndex contents. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/versionedSummarizer.ts:82-120` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerSummarizer.ts:34-147` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/summaryTypes.ts:20-44`

## 4. Behavior

### Graph branch state machine

apply: require non-disposed, tagged revision present; mint child of head, event `{type:append,kind,change,newCommits}`; emit beforeChange, setHead, afterChange. setHead is identity-sensitive no-op and does NOT itself emit. fork shares commit head/family/trim state, constructs independent editor, copies cached count if same head, wires trimmer then emits fork. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:228`

rebaseOnto computes graph rebase, no event when no change; result target commits before transported source commits; emit beforeChange(rebase), update head/count, afterChange. Event change is lazy net state delta (anonymous logical change), distinct from new commit list. merge rebases source onto target without mutating source; appends source commits, lazy-compose source changes, beforeChange→setHead→afterChange. removeAfter walks head backwards to selected ancestor, creates fresh rollback inverses and tags rollbackOf, composes in backward traversal order, then beforeChange(remove)→head reset→afterChange. dispose is idempotent: clear the trimmer subscription, set disposed=true, emit dispose; editing and commit-count reads after disposal fail. Listener cleanup and transaction abort happen in subscribers to dispose. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:348` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:386` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:424` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:485`

### EditManager topology and sequencing

Main shared branch contains trunk, optimistic local branch, per-session peer local branches, sequenceId→commit B-tree and commit revision→sequencing metadata. Additional shared branches have same internal structure and retain common ancestry. Local afterChange append extends local-commit cache; any non-append recomputes path back to trunk. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:823`

Sequence IDs order `(sequenceNumber,indexInBatch??0)`; first commit in new batch has missing index, subsequent indexes1,2,...; another op processed at same seq continues existing batch size. Reference seq lookup uses `{seq,index:Infinity}`, thus includes LAST commit of that sequence, not first. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:888` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:1111` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sequenceIdUtils.ts:16`

Local ack: if revision already has sequencing metadata (e.g. merged shared branch), return. Otherwise SHIFT first optimistic commit; require present; push that already-rebased graph commit onto trunk, register seq/session, invoke onSequenceLocalCommit. Do not decode ack payload and apply it a second time. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:1078`

Remote: rebase/create sender peer branch to closest trunk commit <=reference seq. If peer head==trunk head, append remote commits directly to trunk, advance peer head. Otherwise apply original remote changes to peer branch, merge peer branch into trunk; register all transported source commits with consecutive batch indexes. Finally rebase optimistic local branch onto new trunk. Sender peer branch retains its own authored context, which is essential for later ops from that session. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:888` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:976`

### MinSeq/history trimming

Minimum seq monotonically increases (equal no-op); optional suppress trim protects synchronous listeners. Compute inclusive eviction bound=min(MSN with index∞, local-fork bound, history-retention bound). Local-fork bound is just BEFORE earliest fork base, or trunk head if no forks. History=true keeps all; false/0 permits through head; numeric N retains last N commits excluding sentinel. Find closest trunk commit at/below bound (clamped to oldest retained seq). If already base no-op; rebase peers to new base, delete earlier metadata, keep new base's seq map entry but not metadata, clear new base customMetadata, sever its parent; old commits become unreadable via poison getters, increment trimmed count, emit ancestryTrimmed(revisions). Held local forks therefore constrain collection; peer branches are rebased forward rather than pinning all history forever. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:212` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:368` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:1023`

Summary first trims, then chooses history/MSN/branch-base lower bound; persists retained trunk and peers, not optimistic local branch. Load requires empty manager; reconstruct main trunk first/cache revisions, then child branches at cached bases; create local view at loaded trunk. Do not discard peer histories just because visible tree already loaded. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:482` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:512`

### Submission/reconnect

Attached branch beforeChange append prepares enrichment then submits each commit BEFORE setHead/afterChange. Detached mode instead self-sequences, advances synthetic seq/MSN with trimming suppressed until handlers finish. Submit clones schema into local op metadata so reconnect encoding cannot observe schema mutated by later local edits. Resubmit machine stores enriched commits keyed revision plus enrichment generation; any nonlocal sequenced commit increments generation and invalidates pending enrichment. On first stale resubmit, collect stale prefix of current rebased local commits, enrich together from first parent, store refreshed commits, then submit. Ack removes pending by revision; rollback removes it too. Do not resend original pre-rebase/pre-refresh op blindly. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:348` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:389` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/defaultResubmitMachine.ts:45`

Exact graph/sequence/trim and codec procedures follow. Transaction machinery is included as a source procedure to preserve nested scopes, rollback and commit squashing rather than approximate them as independent edits.

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `shared-tree-core/branch.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:1-534`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type BranchId = SessionSpaceCompressedId | "main";
export type EncodedBranchId = OpSpaceCompressedId;
export type SharedTreeBranchChange<TChange> =
	| {
			type: "append";
			kind: CommitKind;
			change: TaggedChange<TChange>;
			newCommits: readonly [GraphCommit<TChange>, ...GraphCommit<TChange>[]];
	  }
	| {
			type: "remove";
			change: TaggedChange<TChange>;
			removedCommits: readonly [GraphCommit<TChange>, ...GraphCommit<TChange>[]];
	  }
	| {
			type: "rebase";
			change: TaggedChange<TChange> | undefined;
			removedCommits: readonly GraphCommit<TChange>[];
			newCommits: readonly GraphCommit<TChange>[];
	  };
export interface SharedTreeBranchEvents<
	TEditor extends ChangeFamilyEditor,
	TChange,
	TChangeProcessingContext,
> extends BranchTrimmingEvents {
	beforeChange(change: SharedTreeBranchChange<TChange>): void;
	afterChange(change: SharedTreeBranchChange<TChange>): void;
	fork(fork: SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>): void;
	commitSequenced(commit: GraphCommit<TChange>): void;
	dispose(): void;
}
export interface BranchTrimmingEvents {
	ancestryTrimmed(trimmedRevisions: RevisionTag[]): void;
}
export interface BranchTrimState {
	readonly trimmedCommitCount: number;
}
export class SharedTreeBranch<
	TEditor extends ChangeFamilyEditor,
	TChange,
	TChangeProcessingContext,
> {
	readonly #events =
		createEmitter<SharedTreeBranchEvents<TEditor, TChange, TChangeProcessingContext>>();
	public readonly events: Listenable<
		SharedTreeBranchEvents<TEditor, TChange, TChangeProcessingContext>
	> = this.#events;
	public readonly editor: TEditor;
	private disposed = false;
	private logicalCommitCount?: number;
	private branchTrimmer?: Listenable<BranchTrimmingEvents>;
	private unsubscribeBranchTrimmer?: () => void;
	public constructor(
		private head: GraphCommit<TChange>,
		public readonly changeFamily: ChangeFamily<TEditor, TChange, TChangeProcessingContext>,
		private readonly mintRevisionTag: () => RevisionTag,
		private readonly trimState: BranchTrimState,
		private readonly telemetryEventBatcher?: TelemetryEventBatcher<
			keyof RebaseStatsWithDuration
		>,
	) {
		this.editor = this.changeFamily.buildEditor(mintRevisionTag, (change) =>
			this.apply(change, CommitKind.Default, undefined),
		);
	}
	public set trimmer(branchTrimmer: Listenable<BranchTrimmingEvents> | undefined) {
		if (branchTrimmer !== undefined) {
			this.assertNotDisposed();
		}
		this.unsubscribeBranchTrimmer?.();
		this.branchTrimmer = branchTrimmer;
		this.unsubscribeBranchTrimmer = branchTrimmer?.on("ancestryTrimmed", (commit) => {
			this.#events.emit("ancestryTrimmed", commit);
		});
	}
	public setHead(head: GraphCommit<TChange>, commitCountDelta: number): void {
		this.assertNotDisposed();
		if (head === this.head) {
			return;
		}
		if (this.logicalCommitCount !== undefined) {
			this.logicalCommitCount += commitCountDelta;
		}
		this.head = head;
	}
	public apply(
		change: TaggedChange<TChange>,
		kind: CommitKind,
		customMetadata: CustomMetadataTree | undefined,
	): void {
		this.assertNotDisposed();
		const revisionTag = change.revision;
		assert(revisionTag !== undefined, 0xa49  );
		const newHead = mintCommit(this.head, {
			revision: revisionTag,
			change: change.change,
			customMetadata,
		});
		const changeEvent = {
			type: "append",
			kind,
			change,
			newCommits: [newHead],
		} as const;
		this.#events.emit("beforeChange", changeEvent);
		this.setHead(newHead, 1);
		this.#events.emit("afterChange", changeEvent);
	}
	public commitWasSequenced(commit: GraphCommit<TChange>): void {
		this.#events.emit("commitSequenced", commit);
	}
	public getHead(): GraphCommit<TChange> {
		return this.head;
	}
	public getCommitCount(): number {
		this.assertNotDisposed();
		const trimmedCommitCount = this.trimState.trimmedCommitCount;
		if (this.logicalCommitCount === undefined) {
			let count = -1;
			for (
				let commit: GraphCommit<TChange> | undefined = this.head;
				commit !== undefined;
				commit = commit.parent
			) {
				count++;
			}
			this.logicalCommitCount = count + trimmedCommitCount;
		}
		return this.logicalCommitCount - trimmedCommitCount;
	}
	public fork(
		commit: GraphCommit<TChange> = this.head,
		mintRevisionTag: () => RevisionTag = this.mintRevisionTag,
	): SharedTreeBranch<TEditor, TChange, TChangeProcessingContext> {
		this.assertNotDisposed();
		const fork = new SharedTreeBranch(
			commit,
			this.changeFamily,
			mintRevisionTag,
			this.trimState,
		);
		if (commit === this.head) {
			fork.logicalCommitCount = this.logicalCommitCount;
		}
		fork.trimmer = this.branchTrimmer;
		this.#events.emit("fork", fork);
		return fork;
	}
	public rebaseOnto(
		branch: SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>,
		upTo = branch.getHead(),
	): void {
		this.assertNotDisposed();
		const rebaseResult = this.rebaseBranch(this, branch, upTo);
		if (rebaseResult === undefined) {
			return;
		}
		const { newSourceHead, commits } = rebaseResult;
		const { deletedSourceCommits, targetCommits, sourceCommits } = commits;
		assert(hasSome(targetCommits), 0xa83  );
		const newCommits = [...targetCommits, ...sourceCommits];
		const changeEvent = {
			type: "rebase",
			get change() {
				const change = rebaseResult.sourceChange;
				return change === undefined ? undefined : makeAnonChange(change);
			},
			removedCommits: deletedSourceCommits,
			newCommits,
		} as const;
		this.#events.emit("beforeChange", changeEvent);
		this.setHead(newSourceHead, newCommits.length - deletedSourceCommits.length);
		this.#events.emit("afterChange", changeEvent);
	}
	public removeAfter(commit: GraphCommit<TChange>): void {
		if (commit === this.head) {
			return;
		}
		const removedCommits: GraphCommit<TChange>[] = [];
		const inverses: TaggedChange<TChange>[] = [];
		findAncestor([this.head, removedCommits], (c) => {
			if (c !== commit) {
				const revision = this.mintRevisionTag();
				const inverse = this.changeFamily.rebaser.invert(c, true, revision);
				inverses.push(tagRollbackInverse(inverse, revision, c.revision));
				return false;
			}
			return true;
		});
		assert(hasSome(removedCommits), 0xa84  );
		const change = makeAnonChange(this.changeFamily.rebaser.compose(inverses));
		const changeEvent = {
			type: "remove",
			change,
			removedCommits,
		} as const;
		this.#events.emit("beforeChange", changeEvent);
		this.setHead(commit, -removedCommits.length);
		this.#events.emit("afterChange", changeEvent);
	}
	public merge(
		branch: SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>,
	): { sourceCommits: GraphCommit<TChange>[] } | undefined {
		this.assertNotDisposed();
		branch.assertNotDisposed();
		if (branch === this) {
			return undefined;
		}
		const rebaseResult = this.rebaseBranch(branch, this);
		if (rebaseResult === undefined) {
			return undefined;
		}
		const sourceCommits = rebaseResult.commits.sourceCommits;
		assert(hasSome(sourceCommits), 0xa86  );
		const { rebaser } = this.changeFamily;
		const changeEvent = defineLazyCachedProperty(
			{
				type: "append",
				kind: CommitKind.Default,
				newCommits: sourceCommits,
			} as const,
			"change",
			() => makeAnonChange(rebaser.compose(sourceCommits)),
		);
		this.#events.emit("beforeChange", changeEvent);
		this.setHead(rebaseResult.newSourceHead, sourceCommits.length);
		this.#events.emit("afterChange", changeEvent);
		return { sourceCommits };
	}
	private rebaseBranch(
		branch: SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>,
		onto: SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>,
		upTo = onto.getHead(),
	): BranchRebaseResult<TChange> | undefined {
		const { head } = branch;
		if (head === upTo) {
			return undefined;
		}
		const { duration, output } = measure(() =>
			rebaseBranch(this.mintRevisionTag, this.changeFamily, head, upTo, onto.getHead()),
		);
		this.telemetryEventBatcher?.accumulateAndLog({ duration, ...output.telemetryProperties });
		if (this.head === output.newSourceHead) {
			return undefined;
		}
		return output;
	}
	public dispose(): void {
		if (this.disposed) {
			return;
		}
		this.trimmer = undefined;
		this.disposed = true;
		this.#events.emit("dispose");
	}
	private assertNotDisposed(): void {
		assert(!this.disposed, 0x66e  );
	}
}
export function onForkTransitive<T extends { events: Listenable<{ fork(t: T): void }> }>(
	branch: T,
	onFork: (fork: T) => void,
): () => void {
	const offs: (() => void)[] = [];
	offs.push(
		branch.events.on("fork", (fork: T) => {
			offs.push(onForkTransitive(fork, onFork));
			onFork(fork);
		}),
	);
	return () => {
		for (const off of offs) {
			off();
		}
	};
}
```

### Decision procedure: `shared-tree-core/branchCommitEnricher.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branchCommitEnricher.ts:1-61`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class BranchCommitEnricher<TChange> {
	private readonly prepared: WeakMap<GraphCommit<TChange>, TChange> = new WeakMap();
	public constructor(private readonly enricher: ChangeEnricher<TChange>) {}
	public prepareChanges(
		commits: readonly GraphCommit<TChange>[],
		forceValidation: boolean,
	): void {
		if (hasSome(commits)) {
			const startingState = commits[0].parent;
			assert(startingState !== undefined, 0xcc1  );
			const enrichedCommits = this.enricher.enrich(startingState, commits, forceValidation);
			for (const [index, commit] of commits.entries()) {
				const enrichedCommit = enrichedCommits[index];
				assert(enrichedCommit !== undefined, 0xcc2  );
				this.prepared.set(commit, enrichedCommit);
			}
		}
	}
	public retrieveChange(commit: GraphCommit<TChange>): TChange {
		const prepared = this.prepared.get(commit);
		assert(prepared !== undefined, 0x980  );
		this.prepared.delete(commit);
		return prepared;
	}
}
```

### Decision procedure: `shared-tree-core/changeEnricher.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/changeEnricher.ts:1-24`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ChangeEnricher<TChange> {
	enrich(
		context: GraphCommit<TChange>,
		changes: readonly TaggedChange<TChange>[],
		forceValidation: boolean,
	): TChange[];
}
```

### Decision procedure: `shared-tree-core/defaultResubmitMachine.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/defaultResubmitMachine.ts:1-139`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
interface PendingChange<TChange> {
	commit: GraphCommit<TChange>;
	lastEnrichment: number;
}
export class DefaultResubmitMachine<TChange> implements ResubmitMachine<TChange> {
	private readonly pendingChanges: Map<RevisionTag, PendingChange<TChange>> = new Map();
	private currentEnrichment: number = 0;
	public constructor(
		private readonly enricher: ChangeEnricher<TChange>,
		private readonly forceValidation: boolean,
	) {}
	public onCommitSubmitted(commit: GraphCommit<TChange>): void {
		this.pendingChanges.set(commit.revision, {
			commit,
			lastEnrichment: this.currentEnrichment,
		});
	}
	public onCommitRollback(commit: GraphCommit<TChange>): void {
		this.pendingChanges.delete(commit.revision);
	}
	private updateEnrichments(
		revision: RevisionTag,
		getLocalCommits: () => readonly GraphCommit<TChange>[],
	): void {
		const pendingChange = this.pendingChanges.get(revision);
		if (
			pendingChange === undefined ||
			pendingChange.lastEnrichment === this.currentEnrichment
		) {
			return;
		}
		const newCommits = getLocalCommits();
		const staleChanges: {
			readonly pending: PendingChange<TChange>;
			readonly newCommit: GraphCommit<TChange>;
		}[] = [];
		for (const newCommit of newCommits) {
			const pending = this.getPendingChange(newCommit.revision);
			assert(
				pending !== undefined,
				0xbda  ,
			);
			const isStale = pending.lastEnrichment < this.currentEnrichment;
			if (isStale) {
				staleChanges.push({ pending, newCommit });
			} else {
				break;
			}
		}
		assert(
			hasSome(staleChanges) && staleChanges[0].newCommit.revision === revision,
			0xc79  ,
		);
		const startingState = staleChanges[0].newCommit.parent;
		assert(startingState !== undefined, 0xcc3  );
		const enriched = this.enricher.enrich(
			startingState,
			newCommits.slice(0, staleChanges.length),
			this.forceValidation,
		);
		for (const [index, { pending, newCommit }] of staleChanges.entries()) {
			const enrichedChange = enriched[index];
			assert(enrichedChange !== undefined, 0xcc4  );
			const enrichedCommit = { ...newCommit, change: enrichedChange };
			pending.commit = enrichedCommit;
			pending.lastEnrichment = this.currentEnrichment;
		}
	}
	public getEnrichedCommit(
		revision: RevisionTag,
		getLocalCommitsSince: () => readonly GraphCommit<TChange>[],
	): GraphCommit<TChange> | undefined {
		this.updateEnrichments(revision, getLocalCommitsSince);
		const pendingChange = this.pendingChanges.get(revision);
		return pendingChange?.commit;
	}
	private getPendingChange(revision: RevisionTag): PendingChange<TChange> {
		return (
			this.pendingChanges.get(revision) ??
			fail(0xc7a  )
		);
	}
	public onSequencedCommitApplied(revision: RevisionTag, isLocal: boolean): void {
		this.pendingChanges.delete(revision);
		if (!isLocal) {
			this.currentEnrichment++;
		}
	}
}
```

### Decision procedure: `shared-tree-core/editManager.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:1-1339`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const minimumPossibleSequenceNumber: SeqNumber = brand(Number.MIN_SAFE_INTEGER);
const minimumPossibleSequenceId: SequenceId = {
	sequenceNumber: minimumPossibleSequenceNumber,
};
const rootRevision = "root" as const satisfies RevisionTag;
const maxRebaseStatsAggregationCount = 1000;
export class EditManager<
	TEditor extends ChangeFamilyEditor,
	TChangeset,
	TChangeProcessingContext = never,
> {
	private readonly trimmer = createEmitter<BranchTrimmingEvents>();
	private readonly trimState = { trimmedCommitCount: 0 };
	private readonly sharedBranches = new Map<
		BranchId,
		SharedBranch<TEditor, TChangeset, TChangeProcessingContext>
	>();
	private readonly trunkBranches = new BTree<
		SequenceId,
		Set<SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>>
	>(undefined, sequenceIdComparator);
	private minimumSequenceNumber = minimumPossibleSequenceNumber;
	private historyRetention: boolean | number = false;
	private trunkBase: GraphCommit<TChangeset>;
	private readonly telemetryEventBatcher:
		| TelemetryEventBatcher<keyof RebaseStatsWithDuration>
		| undefined;
	public constructor(
		public readonly changeFamily: ChangeFamily<TEditor, TChangeset, TChangeProcessingContext>,
		public readonly localSessionId: SessionId,
		private readonly mintRevisionTag: () => RevisionTag,
		private readonly onSharedBranchCreated?: (branchId: BranchId) => void,
		logger?: TelemetryLoggerExt,
	) {
		this.trunkBase = {
			revision: rootRevision,
			change: changeFamily.rebaser.compose([]),
			customMetadata: undefined,
			wasTrimmed: true,
		};
		if (logger !== undefined) {
			this.telemetryEventBatcher = new TelemetryEventBatcher(
				{
					eventName: "rebaseProcessing",
					category: "performance",
				},
				logger,
				maxRebaseStatsAggregationCount,
			);
		}
		const mainTrunk = new SharedTreeBranch(
			this.trunkBase,
			changeFamily,
			mintRevisionTag,
			this.trimState,
			this.telemetryEventBatcher,
		);
		mainTrunk.trimmer = this.trimmer;
		this.createAndAddSharedBranch("main", "main", undefined, undefined, mainTrunk);
	}
	public getHistoryRetention(): boolean | number {
		return this.historyRetention;
	}
	public setHistoryRetention(value: boolean | number): void {
		assert(
			typeof value === "boolean" || (Number.isSafeInteger(value) && value >= 0),
			0xd79  ,
		);
		this.historyRetention = value;
		this.trimHistory();
	}
	private getUpperTrimmingBoundForHistory(): SequenceId {
		if (this.historyRetention === true) {
			return minimumPossibleSequenceId;
		}
		const sequenceIdToCommit = this.getSharedBranch("main").sequenceIdToCommit;
		if (this.historyRetention === false || this.historyRetention === 0) {
			return sequenceIdToCommit.maxKey() ?? minimumPossibleSequenceId;
		}
		if (this.historyRetention < sequenceIdToCommit.size - 1) {
			let remaining = this.historyRetention;
			for (const [sequenceId] of sequenceIdToCommit.entriesReversed()) {
				remaining--;
				if (remaining === 0) {
					return getUpperBoundOfPreviousSequenceId(sequenceId);
				}
			}
		}
		return minimumPossibleSequenceId;
	}
	private getUpperTrimmingBoundForLocalForks(): SequenceId {
		const minimumBranchBaseSequenceId = this.trunkBranches.minKey();
		return minimumBranchBaseSequenceId === undefined
			? (this.getSharedBranch("main").sequenceIdToCommit.maxKey() ?? minimumPossibleSequenceId)
			: getUpperBoundOfPreviousSequenceId(minimumBranchBaseSequenceId);
	}
	private getUpperTrimmingBoundForMinimumSequenceNumber(): SequenceId {
		return {
			sequenceNumber: this.minimumSequenceNumber,
			indexInBatch: Number.POSITIVE_INFINITY,
		};
	}
	public getLocalBranch(
		branchId: BranchId,
	): SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext> {
		return this.getSharedBranch(branchId).localBranch;
	}
	public getSharedBranchName(branchId: BranchId): string | undefined {
		return this.getSharedBranch(branchId).branchName;
	}
	private getSharedBranch(
		branchId: BranchId,
	): SharedBranch<TEditor, TChangeset, TChangeProcessingContext> {
		const branch = this.sharedBranches.get(branchId);
		if (branch === undefined) {
			throw new UsageError("No shared branch with such ID");
		}
		return branch;
	}
	private registerBranch(
		branch: SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>,
	): void {
		this.trackBranch(branch);
		const offBeforeRebase = branch.events.on("beforeChange", (args) => {
			if (args.type === "rebase") {
				this.untrackBranch(branch);
			}
		});
		const offAfterRebase = branch.events.on("afterChange", (args) => {
			if (args.type === "rebase") {
				this.trackBranch(branch);
				this.trimHistory();
			}
		});
		const offDispose = branch.events.on("dispose", () => {
			this.untrackBranch(branch);
			this.trimHistory();
			offBeforeRebase();
			offAfterRebase();
			offDispose();
		});
	}
	private trackBranch(
		b: SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>,
	): void {
		const main = this.getSharedBranch("main");
		const trunkCommit =
			findCommonAncestor(main.trunk.getHead(), b.getHead()) ??
			fail(0xad2  );
		const sequenceId = main.getCommitSequenceId(trunkCommit.revision);
		const branches = getOrCreate(this.trunkBranches, sequenceId, () => new Set());
		assert(!branches.has(b), 0x670  );
		branches.add(b);
	}
	private untrackBranch(
		b: SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>,
	): void {
		const main = this.getSharedBranch("main");
		const trunkCommit =
			findCommonAncestor(main.trunk.getHead(), b.getHead()) ??
			fail(0xad3  );
		const sequenceId = main.getCommitSequenceId(trunkCommit.revision);
		const branches =
			this.trunkBranches.get(sequenceId) ?? fail(0xad4  );
		assert(branches.delete(b), 0x671  );
		if (branches.size === 0) {
			this.trunkBranches.delete(sequenceId);
		}
	}
	public getLatestSequenceNumber(): SeqNumber | undefined {
		let maxSequenceNumber: SeqNumber | undefined;
		for (const branch of this.sharedBranches.values()) {
			const branchMax = branch.getCommitSequenceId(
				branch.trunk.getHead().revision,
			).sequenceNumber;
			if (maxSequenceNumber === undefined || maxSequenceNumber < branchMax) {
				maxSequenceNumber = branchMax;
			}
		}
		return maxSequenceNumber;
	}
	public advanceMinimumSequenceNumber(
		minimumSequenceNumber: SeqNumber,
		allowHistoryTrimming = true,
	): void {
		if (minimumSequenceNumber === this.minimumSequenceNumber) {
			return;
		}
		assert(
			minimumSequenceNumber > this.minimumSequenceNumber,
			0x476  ,
		);
		this.minimumSequenceNumber = minimumSequenceNumber;
		if (allowHistoryTrimming) {
			this.trimHistory();
		}
	}
	private trimHistory(): void {
		const msnBound = this.getUpperTrimmingBoundForMinimumSequenceNumber();
		const forkBound = this.getUpperTrimmingBoundForLocalForks();
		const historyBound = this.getUpperTrimmingBoundForHistory();
		const trunkTailSequenceId = minSequenceId(
			msnBound,
			minSequenceId(forkBound, historyBound),
		);
		const mainBranch = this.getSharedBranch("main");
		const [sequenceId, latestEvicted] = mainBranch.getClosestTrunkCommit(
			maxSequenceId(
				trunkTailSequenceId,
				mainBranch.sequenceIdToCommit.minKey() ?? minimumPossibleSequenceId,
			),
		);
		if (latestEvicted === this.trunkBase) {
			return;
		}
		const newTrunkBase = latestEvicted as Mutable<GraphCommit<TChangeset>>;
		const trimmedCommits = getPathFromBase(newTrunkBase, this.trunkBase) as Mutable<
			GraphCommit<TChangeset>
		>[];
		const trimmedRevisions = trimmedCommits.map((c) => c.revision);
		mainBranch.trimHistory(latestEvicted, sequenceId);
		newTrunkBase.customMetadata = undefined;
		for (const commit of trimmedCommits.slice(0, -1)) {
			Reflect.defineProperty(commit, "change", {
				get: () => fail(0xa5e  ),
			});
			Reflect.defineProperty(commit, "revision", {
				get: () =>
					assert(
						false,
						0xa5f  ,
					),
			});
			Reflect.defineProperty(commit, "customMetadata", {
				get: () =>
					fail(0xd36  ),
			});
			Reflect.defineProperty(commit, "parent", {
				get: () =>
					assert(false, 0xa60  ),
			});
			commit.wasTrimmed = true;
		}
		delete newTrunkBase.parent;
		newTrunkBase.wasTrimmed = true;
		this.trunkBase = newTrunkBase;
		this.trimState.trimmedCommitCount += trimmedRevisions.length;
		this.trimmer.emit("ancestryTrimmed", trimmedRevisions);
	}
	public isEmpty(): boolean {
		for (const branch of this.sharedBranches.values()) {
			if (!branch.isEmpty(this.trunkBase)) {
				return false;
			}
		}
		return this.minimumSequenceNumber === minimumPossibleSequenceNumber;
	}
	public getSummaryData(): SummaryData<TChangeset> {
		this.trimHistory();
		const mainBranch = this.getSharedBranch("main");
		const minSeqNumberToSummarize: SequenceId = {
			sequenceNumber: brand(this.minimumSequenceNumber + 1),
		};
		const historyBound = this.getUpperTrimmingBoundForHistory();
		let minBaseSeqId = minSequenceId(
			minSeqNumberToSummarize,
			mainBranch.sequenceIdToCommit.nextHigherKey(historyBound) ?? minSeqNumberToSummarize,
		);
		const branches = new Map<BranchId, SharedBranchSummaryData<TChangeset>>();
		for (const [branchId, branch] of this.sharedBranches) {
			if (branchId !== "main") {
				const branchSummary = branch.getSummaryData(
					minSeqNumberToSummarize,
					this.trunkBase.revision,
				);
				branches.set(branchId, branchSummary);
				assert(branchSummary.base !== undefined, 0xc57  );
				const baseSequenceId = mainBranch.getCommitSequenceId(branchSummary.base);
				minBaseSeqId = minSequenceId(minBaseSeqId, baseSequenceId);
			}
		}
		const mainSummary = mainBranch.getSummaryData(minBaseSeqId, this.trunkBase.revision);
		return { main: mainSummary, branches, originator: this.localSessionId };
	}
	public loadSummaryData(data: SummaryData<TChangeset>): void {
		assert(
			this.isEmpty(),
			0x68a  ,
		);
		const trunkRevisionCache = new Map<RevisionTag, GraphCommit<TChangeset>>();
		trunkRevisionCache.set(this.trunkBase.revision, this.trunkBase);
		const mainBranch =
			this.sharedBranches.get("main") ?? fail(0xc58  );
		mainBranch.loadSummaryData(data.main, trunkRevisionCache);
		if (data.branches !== undefined) {
			for (const [branchId, branchData] of data.branches) {
				const baseCommit =
					trunkRevisionCache.get(branchData.base ?? rootRevision) ??
					fail(0xd87  );
				const branch = this.createSharedBranch(
					branchId,
					branchData.name,
					branchData.session,
					mainBranch,
					mainBranch.trunk.fork(baseCommit),
				);
				branch.loadSummaryData(branchData, trunkRevisionCache);
				this.addSharedBranch(branchId, branch);
			}
		}
	}
	public getTrunkHead(branchId: BranchId): GraphCommit<TChangeset> {
		return this.getSharedBranch(branchId).trunk.getHead();
	}
	public getTrunkChanges(branchId: BranchId): TChangeset[] {
		return this.getTrunkCommits(branchId).map((c) => c.change);
	}
	public getTrunkCommits(branchId: BranchId): GraphCommit<TChangeset>[] {
		return getPathFromBase(this.getTrunkHead(branchId), this.trunkBase);
	}
	public getLocalCommits(branchId: BranchId): readonly GraphCommit<TChangeset>[] {
		const branch = this.getSharedBranch(branchId);
		return branch.getLocalCommits();
	}
	public getLongestBranchLength(): number {
		let max = 0;
		for (const branch of this.sharedBranches.values()) {
			max = Math.max(max, branch.getLongestBranchLength());
		}
		return max;
	}
	public sequenceBranchCreation(
		sessionId: SessionId,
		referenceSequenceNumber: SeqNumber,
		branchId: BranchId,
		branchName?: string,
	): void {
		if (sessionId === this.localSessionId) {
			assert(this.sharedBranches.has(branchId), 0xc59  );
			return;
		}
		const mainBranch = this.getSharedBranch("main");
		const branchTrunk = mainBranch.rebasePeer(sessionId, referenceSequenceNumber).fork();
		this.createAndAddSharedBranch(branchId, branchName, sessionId, mainBranch, branchTrunk);
	}
	public addNewBranch(branchId: BranchId, branchName?: string): void {
		const main = this.getSharedBranch("main") ?? fail(0xc5a  );
		this.createAndAddSharedBranch(
			branchId,
			branchName,
			this.localSessionId,
			main,
			this.getLocalBranch("main").fork(),
		);
	}
	public getSharedBranchIds(): BranchId[] {
		return [...this.sharedBranches.keys()];
	}
	public removeBranch(branchId: BranchId): void {
		assert(branchId !== "main", 0xc5b  );
		const hadBranch = this.sharedBranches.delete(branchId);
		assert(hadBranch, 0xc5c  );
	}
	private createAndAddSharedBranch(
		branchId: BranchId,
		branchName: string | undefined,
		sessionId: SessionId | undefined,
		parent: SharedBranch<TEditor, TChangeset, TChangeProcessingContext> | undefined,
		branch: SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>,
	): SharedBranch<TEditor, TChangeset, TChangeProcessingContext> {
		const sharedBranch = this.createSharedBranch(
			branchId,
			branchName,
			sessionId,
			parent,
			branch,
		);
		this.addSharedBranch(branchId, sharedBranch);
		return sharedBranch;
	}
	private addSharedBranch(
		branchId: BranchId,
		branch: SharedBranch<TEditor, TChangeset, TChangeProcessingContext>,
	): void {
		assert(
			!this.sharedBranches.has(branchId),
			0xc5d  ,
		);
		this.sharedBranches.set(branchId, branch);
		onForkTransitive(branch.localBranch, (fork) => this.registerBranch(fork));
		if (branchId !== "main") {
			this.registerBranch(branch.localBranch);
			this.onSharedBranchCreated?.(branchId);
		}
	}
	private createSharedBranch(
		branchId: BranchId,
		branchName: string | undefined,
		sessionId: SessionId | undefined,
		parent: SharedBranch<TEditor, TChangeset, TChangeProcessingContext> | undefined,
		branch: SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>,
	): SharedBranch<TEditor, TChangeset, TChangeProcessingContext> {
		const sharedBranch = new SharedBranch(
			parent,
			branch,
			branchId,
			branchName,
			sessionId,
			minimumPossibleSequenceId,
			this.changeFamily,
			this.mintRevisionTag,
			this.trimmer,
			this.trimState,
			this.telemetryEventBatcher,
		);
		return sharedBranch;
	}
	public addSequencedChanges(
		newCommits: readonly GraphCommit<TChangeset>[],
		sessionId: SessionId,
		sequenceNumber: SeqNumber,
		referenceSequenceNumber: SeqNumber,
		branchId: BranchId,
		allowHistoryTrimming = true,
	): void {
		assert(newCommits.length > 0, 0xad8  );
		assert(
			sequenceNumber > this.minimumSequenceNumber,
			0x713  ,
		);
		const branch = this.getSharedBranch(branchId);
		const onSequenceLocalCommit = (
			commit: GraphCommit<TChangeset>,
			sequenceId: SequenceId,
			previousSequenceId: SequenceId,
		): void => {
			branch.localBranch.commitWasSequenced(commit);
			const currentBranches = this.trunkBranches.get(previousSequenceId);
			if (currentBranches !== undefined) {
				const newBranches = getOrCreate(this.trunkBranches, sequenceId, () => new Set());
				for (const forkedBranch of currentBranches) {
					if (findAncestor(forkedBranch.getHead(), (c) => c === commit) !== undefined) {
						newBranches.add(forkedBranch);
						currentBranches.delete(forkedBranch);
						forkedBranch.commitWasSequenced(commit);
					}
				}
				if (currentBranches.size === 0) {
					this.trunkBranches.delete(previousSequenceId);
				}
				if (newBranches.size === 0) {
					this.trunkBranches.delete(sequenceId);
				}
			}
		};
		const areLocalCommits = sessionId === this.localSessionId;
		branch.addSequencedChanges(
			newCommits,
			sessionId,
			sequenceNumber,
			areLocalCommits,
			referenceSequenceNumber,
			onSequenceLocalCommit,
		);
		if (allowHistoryTrimming) {
			this.trimHistory();
		}
	}
	public findLocalCommit(
		branchId: BranchId,
		revision: RevisionTag,
	): [commit: GraphCommit<TChangeset>, commitsAfter: GraphCommit<TChangeset>[]] {
		const commits: GraphCommit<TChangeset>[] = [];
		const commit = findAncestor(
			[this.getSharedBranch(branchId).localBranch.getHead(), commits],
			(c) => c.revision === revision,
		);
		assert(commit !== undefined, 0x599  );
		return [commit, commits];
	}
}
export interface SummaryData<TChangeset> {
	readonly originator?: SessionId;
	readonly main: SharedBranchSummaryData<TChangeset>;
	readonly branches?: ReadonlyMap<BranchId, SharedBranchSummaryData<TChangeset>>;
}
export interface SharedBranchSummaryData<TChangeset> {
	readonly id?: BranchId;
	readonly name?: string;
	readonly session?: SessionId;
	readonly author?: string;
	readonly base?: RevisionTag;
	readonly trunk: readonly SequencedCommit<TChangeset>[];
	readonly peerLocalBranches: ReadonlyMap<SessionId, SummarySessionBranch<TChangeset>>;
}
function getPathFromBase<TCommit extends { parent?: TCommit }>(
	branchHead: TCommit,
	baseBranchHead: TCommit,
): TCommit[] {
	const path: TCommit[] = [];
	assert(
		findCommonAncestor([branchHead, path], baseBranchHead) !== undefined,
		0x573  ,
	);
	return path;
}
class SharedBranch<TEditor extends ChangeFamilyEditor, TChangeset, TChangeProcessingContext> {
	public readonly localBranch: SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>;
	private readonly peerLocalBranches: Map<
		SessionId,
		SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>
	> = new Map();
	public readonly sequenceIdToCommit = new BTree<SequenceId, GraphCommit<TChangeset>>(
		undefined,
		sequenceIdComparator,
	);
	private readonly localCommits: GraphCommit<TChangeset>[] = [];
	private readonly commitMetadata = new Map<
		RevisionTag,
		{ sequenceId: SequenceId; sessionId: SessionId }
	>();
	public constructor(
		public readonly parentBranch:
			| SharedBranch<TEditor, TChangeset, TChangeProcessingContext>
			| undefined,
		public readonly trunk: SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext>,
		private readonly id: BranchId,
		public readonly branchName: string | undefined,
		private readonly sessionId: SessionId | undefined,
		baseCommitSequenceId: SequenceId,
		private readonly changeFamily: ChangeFamily<TEditor, TChangeset, TChangeProcessingContext>,
		private readonly mintRevisionTag: () => RevisionTag,
		branchTrimmer: Listenable<BranchTrimmingEvents>,
		private readonly trimState: BranchTrimState,
		telemetryEventBatcher: TelemetryEventBatcher<keyof RebaseStatsWithDuration> | undefined,
	) {
		this.localBranch = new SharedTreeBranch(
			this.trunk.getHead(),
			changeFamily,
			mintRevisionTag,
			trimState,
			telemetryEventBatcher,
		);
		this.localBranch.trimmer = branchTrimmer;
		this.sequenceIdToCommit.set(baseCommitSequenceId, this.trunk.getHead());
		this.localBranch.events.on("afterChange", (event) => {
			if (event.type === "append") {
				for (const commit of event.newCommits) {
					this.localCommits.push(commit);
				}
			} else {
				this.localCommits.length = 0;
				findCommonAncestor(
					[this.localBranch.getHead(), this.localCommits],
					this.trunk.getHead(),
				);
			}
		});
	}
	public addSequencedChanges(
		newCommits: readonly GraphCommit<TChangeset>[],
		sessionId: SessionId,
		sequenceNumber: SeqNumber,
		areLocalCommits: boolean,
		referenceSequenceNumber: SeqNumber,
		onSequenceLocalCommit: OnSequenceCommit<TChangeset>,
	): void {
		assert(
			sequenceNumber >=
				(this.sequenceIdToCommit.maxKey()?.sequenceNumber ?? minimumPossibleSequenceNumber),
			0xa64  ,
		);
		const batchSize = this.getBatchSize(sequenceNumber);
		let nextSequenceId =
			batchSize === 0
				? {
						sequenceNumber,
					}
				: {
						sequenceNumber,
						indexInBatch: batchSize,
					};
		if (areLocalCommits) {
			for (const { revision } of newCommits) {
				this.sequenceLocalCommit(revision, nextSequenceId, sessionId, onSequenceLocalCommit);
				nextSequenceId = getNextSequenceId(nextSequenceId);
			}
			return;
		}
		const peerLocalBranch = this.rebasePeer(sessionId, referenceSequenceNumber);
		if (peerLocalBranch.getHead() === this.trunk.getHead()) {
			for (const newCommit of newCommits) {
				this.pushCommitToTrunk(nextSequenceId, { ...newCommit, sessionId });
				nextSequenceId = getNextSequenceId(nextSequenceId);
			}
			peerLocalBranch.setHead(this.trunk.getHead(), newCommits.length);
		} else {
			for (const newCommit of newCommits) {
				peerLocalBranch.apply(
					tagChange(newCommit.change, newCommit.revision),
					CommitKind.Default,
					newCommit.customMetadata,
				);
			}
			const result = this.trunk.merge(peerLocalBranch);
			if (result !== undefined) {
				for (const sourceCommit of result.sourceCommits) {
					this.sequenceIdToCommit.set(nextSequenceId, sourceCommit);
					this.commitMetadata.set(sourceCommit.revision, {
						sequenceId: nextSequenceId,
						sessionId,
					});
					nextSequenceId = getNextSequenceId(nextSequenceId);
				}
			}
		}
		this.localBranch.rebaseOnto(this.trunk);
	}
	public isEmpty(baseCommit: GraphCommit<TChangeset>): boolean {
		return (
			this.trunk.getHead() === baseCommit &&
			this.peerLocalBranches.size === 0 &&
			this.localBranch.getHead() === this.trunk.getHead()
		);
	}
	public rebasePeer(
		sessionId: SessionId,
		referenceSequenceNumber: SeqNumber,
	): SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext> {
		const [, baseRevisionInTrunk] = this.getClosestTrunkCommit(referenceSequenceNumber);
		const peerLocalBranch = getOrCreate(
			this.peerLocalBranches,
			sessionId,
			() =>
				new SharedTreeBranch(
					baseRevisionInTrunk,
					this.changeFamily,
					this.mintRevisionTag,
					this.trimState,
				),
		);
		peerLocalBranch.rebaseOnto(this.trunk, baseRevisionInTrunk);
		return peerLocalBranch;
	}
	public getPeerBranchOrTrunk(
		sessionId: SessionId,
	): SharedTreeBranch<TEditor, TChangeset, TChangeProcessingContext> {
		return this.peerLocalBranches.get(sessionId) ?? this.trunk;
	}
	public getLongestBranchLength(): number {
		let max = 0;
		const trunkHead = this.trunk.getHead();
		for (const branch of this.peerLocalBranches.values()) {
			const branchPath = getPathFromBase(branch.getHead(), trunkHead);
			if (branchPath.length > max) {
				max = branchPath.length;
			}
		}
		const localPath = getPathFromBase(this.localBranch.getHead(), trunkHead);
		return Math.max(max, localPath.length);
	}
	public trimHistory(newBase: GraphCommit<TChangeset>, sequenceId: SequenceId): void {
		this.rebasePeers(newBase);
		this.sequenceIdToCommit.editRange(
			minimumPossibleSequenceId,
			sequenceId,
			true,
			(s, commit) => {
				this.commitMetadata.delete(commit.revision);
				if (equalSequenceIds(s, sequenceId)) {
					assert(
						commit === newBase,
						0x729  ,
					);
				} else {
					return { delete: true };
				}
			},
		);
		const trunkSize = getPathFromBase(this.trunk.getHead(), newBase).length;
		assert(
			this.sequenceIdToCommit.size === trunkSize + 1,
			0x744  ,
		);
		assert(
			this.commitMetadata.size === trunkSize,
			0x745  ,
		);
	}
	private rebasePeers(commit: GraphCommit<TChangeset>): void {
		for (const [, branch] of this.peerLocalBranches) {
			branch.rebaseOnto(this.trunk, commit);
		}
		this.commitMetadata.delete(commit.revision);
	}
	public getLocalCommits(): readonly GraphCommit<TChangeset>[] {
		return this.localCommits;
	}
	private sequenceLocalCommit(
		revision: RevisionTag,
		sequenceId: SequenceId,
		sessionId: SessionId,
		onSequenceLocalCommit: OnSequenceCommit<TChangeset>,
	): void {
		if (this.commitMetadata.has(revision)) {
			return;
		}
		const firstLocalCommit = this.localCommits.shift();
		assert(
			firstLocalCommit !== undefined,
			0x6b5  ,
		);
		const prevSequenceId = this.getCommitSequenceId(this.trunk.getHead().revision);
		this.pushGraphCommitToTrunk(sequenceId, firstLocalCommit, sessionId);
		onSequenceLocalCommit(firstLocalCommit, sequenceId, prevSequenceId);
	}
	public getClosestTrunkCommit(searchBy: SeqNumber): [SequenceId, GraphCommit<TChangeset>];
	public getClosestTrunkCommit(searchBy: SequenceId): [SequenceId, GraphCommit<TChangeset>];
	public getClosestTrunkCommit(
		searchBy: SeqNumber | SequenceId,
	): [SequenceId, GraphCommit<TChangeset>] {
		const sequenceId: SequenceId =
			typeof searchBy === "number"
				? {
						sequenceNumber: searchBy,
						indexInBatch: Number.POSITIVE_INFINITY,
					}
				: searchBy;
		const commit = this.sequenceIdToCommit.getPairOrNextLower(sequenceId);
		assert(commit !== undefined, 0x746  );
		return commit;
	}
	private pushGraphCommitToTrunk(
		sequenceId: SequenceId,
		graphCommit: GraphCommit<TChangeset>,
		sessionId: SessionId,
	): void {
		this.trunk.setHead(graphCommit, 1);
		this.registerSequencedCommit(sequenceId, sessionId, graphCommit);
	}
	private pushCommitToTrunk(sequenceId: SequenceId, commit: Commit<TChangeset>): void {
		const mintedCommit = mintCommit(this.trunk.getHead(), commit);
		this.pushGraphCommitToTrunk(sequenceId, mintedCommit, commit.sessionId);
	}
	private registerSequencedCommit(
		sequenceId: SequenceId,
		sessionId: SessionId,
		commit: GraphCommit<TChangeset>,
	): void {
		this.sequenceIdToCommit.set(sequenceId, commit);
		this.commitMetadata.set(commit.revision, { sequenceId, sessionId });
	}
	public getCommitSequenceId(commitRevision: RevisionTag): SequenceId {
		const id = this.commitMetadata.get(commitRevision)?.sequenceId;
		if (id === undefined) {
			return minimumPossibleSequenceId;
		}
		return id;
	}
	private getBatchSize(sequenceNumber: SeqNumber): number {
		const startSequenceId: SequenceId = {
			sequenceNumber,
		};
		const endSequenceId: SequenceId = {
			sequenceNumber: brand((sequenceNumber as number) + 1),
		};
		return this.sequenceIdToCommit.getRange(startSequenceId, endSequenceId, false).length;
	}
	public getSummaryData(
		minSeqNumberToSummarize: SequenceId,
		trunkBaseRevision: RevisionTag,
	): SharedBranchSummaryData<TChangeset> {
		assert(
			this.localBranch.getHead() === this.trunk.getHead(),
			0xc5e  ,
		);
		let parentHead: GraphCommit<TChangeset>;
		if (this.parentBranch === undefined) {
			const oldestCommitInCollabWindow =
				this.getClosestTrunkCommit(minSeqNumberToSummarize)[1];
			parentHead = oldestCommitInCollabWindow.parent ?? oldestCommitInCollabWindow;
		} else {
			parentHead = this.parentBranch.trunk.getHead();
		}
		const childBranchTrunkCommits: GraphCommit<TChangeset>[] = [];
		const forkPointFromMainTrunk = findCommonAncestor(
			[this.trunk.getHead(), childBranchTrunkCommits],
			parentHead,
		);
		assert(
			forkPointFromMainTrunk !== undefined,
			0xc5f  ,
		);
		const trunk = childBranchTrunkCommits.map((c) => {
			const metadata =
				this.commitMetadata.get(c.revision) ??
				fail(0xad5  );
			const commit: SequencedCommit<TChangeset> = {
				change: c.change,
				revision: c.revision,
				sequenceNumber: metadata.sequenceId.sequenceNumber,
				sessionId: metadata.sessionId,
				customMetadata: c.customMetadata,
			};
			if (metadata.sequenceId.indexInBatch !== undefined) {
				commit.indexInBatch = metadata.sequenceId.indexInBatch;
			}
			return commit;
		});
		const peerLocalBranches = new Map<SessionId, SummarySessionBranch<TChangeset>>(
			mapIterable(this.peerLocalBranches.entries(), ([sessionId, branch]) => {
				const branchPath: GraphCommit<TChangeset>[] = [];
				const ancestor =
					findCommonAncestor([branch.getHead(), branchPath], this.trunk.getHead()) ??
					fail(0xad6  );
				const base =
					ancestor.revision === trunkBaseRevision ? rootRevision : ancestor.revision;
				return [
					sessionId,
					{
						base,
						commits: branchPath.map((c) => {
							const commit: Commit<TChangeset> = {
								change: c.change,
								revision: c.revision,
								sessionId,
								customMetadata: c.customMetadata,
							};
							return commit;
						}),
					},
				];
			}),
		);
		const trunkBase =
			this.parentBranch === undefined ? undefined : forkPointFromMainTrunk.revision;
		return {
			trunk,
			peerLocalBranches,
			base: trunkBase,
			id: this.id,
			name: this.branchName,
			session: this.sessionId,
		};
	}
	public loadSummaryData(
		data: SharedBranchSummaryData<TChangeset>,
		trunkRevisionCache: Map<RevisionTag, GraphCommit<TChangeset>>,
	): void {
		assert(
			(this.parentBranch === undefined) === (data.base === undefined),
			0xc60  ,
		);
		let trunkHead = this.trunk.getHead();
		assert(
			trunkHead.revision === (data.base ?? rootRevision) &&
				this.localBranch.getHead() === trunkHead,
			0xc61  ,
		);
		for (const c of data.trunk) {
			const sequenceId: SequenceId =
				c.indexInBatch === undefined
					? {
							sequenceNumber: c.sequenceNumber,
						}
					: {
							sequenceNumber: c.sequenceNumber,
							indexInBatch: c.indexInBatch,
						};
			const commit = mintCommit(trunkHead, c);
			this.sequenceIdToCommit.set(sequenceId, commit);
			this.commitMetadata.set(c.revision, {
				sequenceId,
				sessionId: c.sessionId,
			});
			trunkRevisionCache.set(c.revision, commit);
			trunkHead = commit;
		}
		this.trunk.setHead(trunkHead, data.trunk.length);
		this.localBranch.setHead(this.trunk.getHead(), data.trunk.length);
		for (const [sessionId, branch] of data.peerLocalBranches) {
			const commit =
				trunkRevisionCache.get(branch.base) ??
				fail(0xad7  );
			let branchHead = commit;
			for (const c of branch.commits) {
				branchHead = mintCommit(branchHead, c);
			}
			this.peerLocalBranches.set(
				sessionId,
				new SharedTreeBranch(
					branchHead,
					this.changeFamily,
					this.mintRevisionTag,
					this.trimState,
				),
			);
		}
	}
}
function getNextSequenceId(sequenceId: SequenceId): SequenceId {
	return {
		sequenceNumber: sequenceId.sequenceNumber,
		indexInBatch: (sequenceId.indexInBatch ?? 0) + 1,
	};
}
type OnSequenceCommit<TChangeset> = (
	commit: GraphCommit<TChangeset>,
	sequenceId: SequenceId,
	prevSequenceId: SequenceId,
) => void;
```

### Decision procedure: `shared-tree-core/editManagerSummarizer.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerSummarizer.ts:1-147`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const stringKey = "String";
export const enum EditManagerSummaryFormatVersion {
	v1 = 1,
	v2 = 2,
	vLatest = v2,
}
const supportedVersions = new Set<EditManagerSummaryFormatVersion>([
	EditManagerSummaryFormatVersion.v1,
	EditManagerSummaryFormatVersion.v2,
]);
function minVersionToEditManagerSummaryFormatVersion(
	version: OldestSupportedClientVersion,
): EditManagerSummaryFormatVersion {
	return EditManagerSummaryFormatVersion.v2;
}
export class EditManagerSummarizer<TChangeset, TChangeProcessingContext>
	extends VersionedSummarizer<EditManagerSummaryFormatVersion>
	implements Summarizable
{
	public static readonly key = "EditManager";
	public constructor(
		private readonly editManager: EditManager<
			ChangeFamilyEditor,
			TChangeset,
			TChangeProcessingContext
		>,
		private readonly codec: IJsonCodec<
			SummaryData<TChangeset>,
			JsonCompatibleReadOnly,
			JsonCompatibleReadOnly,
			EditManagerEncodingContext<TChangeset>,
			EditManagerDecodingContext
		>,
		private readonly idCompressor: IIdCompressor,
		minVersionForCollab: OldestSupportedClientVersion,
		private readonly schemaAndPolicy?: SchemaAndPolicy,
		private readonly healing?: IdentifierHealingConfig,
	) {
		super(
			EditManagerSummarizer.key,
			minVersionToEditManagerSummaryFormatVersion(minVersionForCollab),
			supportedVersions,
			true  ,
		);
	}
	protected summarizeInternal(props: {
		stringify: SummaryElementStringifier;
		fullTree?: boolean;
		trackState?: boolean;
		telemetryContext?: ITelemetryContext;
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext;
		builder: SummaryTreeBuilder;
	}): void {
		const { stringify, builder } = props;
		const context: EditManagerEncodingContext<TChangeset> = {
			idCompressor: this.idCompressor,
			schema: this.schemaAndPolicy,
			hasSchemaChange: (change) => this.editManager.changeFamily.hasSchemaChange(change),
			isSummary: true,
		};
		const jsonCompatible = this.codec.encode(this.editManager.getSummaryData(), context);
		const dataString = stringify(jsonCompatible);
		builder.addBlob(stringKey, dataString);
	}
	protected async loadInternal(
		services: IChannelStorageService,
		parse: SummaryElementParser,
	): Promise<void> {
		const schemaBuffer: ArrayBufferLike = await services.readBlob(stringKey);
		assert(
			this.editManager.isEmpty(),
			0x42c  ,
		);
		const summary = parse(bufferToString(schemaBuffer, "utf8")) as JsonCompatibleReadOnly;
		const data = this.codec.decode(summary, {
			idCompressor: this.idCompressor,
			isSummary: true,
			healing: this.healing,
		});
		this.editManager.loadSummaryData(data);
	}
}
```

### Decision procedure: `shared-tree-core/messageTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageTypes.ts:1-28`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type DecodedMessage<TChange> = CommitMessage<TChange> | BranchMessage;
export interface MessageBase {
	sessionId: SessionId;
}
export interface CommitMessage<TChange> extends MessageBase {
	type: "commit";
	commit: GraphCommit<TChange>;
	branchId: BranchId;
}
export interface BranchMessage extends MessageBase {
	type: "branch";
	branchId: BranchId;
	branchName?: string;
}
```

### Decision procedure: `shared-tree-core/resubmitMachine.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/resubmitMachine.ts:1-46`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ResubmitMachine<TChange> {
	getEnrichedCommit(
		revision: RevisionTag,
		getLocalCommitsSince: () => readonly GraphCommit<TChange>[],
	): GraphCommit<TChange> | undefined;
	onCommitSubmitted(commit: GraphCommit<TChange>): void;
	onCommitRollback(commit: GraphCommit<TChange>): void;
	onSequencedCommitApplied(revision: RevisionTag, isLocal: boolean): void;
}
```

### Decision procedure: `shared-tree-core/sequenceIdUtils.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sequenceIdUtils.ts:1-49`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const sequenceIdComparator = (a: SequenceId, b: SequenceId): number =>
	a.sequenceNumber === b.sequenceNumber
		? a.indexInBatch === b.indexInBatch
			? 0
			: (a.indexInBatch ?? 0) - (b.indexInBatch ?? 0)
		: a.sequenceNumber - b.sequenceNumber;
export const equalSequenceIds = (a: SequenceId, b: SequenceId): boolean =>
	sequenceIdComparator(a, b) === 0;
export const minSequenceId = (a: SequenceId, b: SequenceId): SequenceId =>
	sequenceIdComparator(a, b) < 0 ? a : b;
export const maxSequenceId = (a: SequenceId, b: SequenceId): SequenceId =>
	sequenceIdComparator(a, b) > 0 ? a : b;
export const getUpperBoundOfPreviousSequenceId = (sequenceId: SequenceId): SequenceId => {
	assert(
		sequenceId.indexInBatch === undefined || Number.isFinite(sequenceId.indexInBatch),
		0xabc  ,
	);
	return sequenceId.indexInBatch === undefined || sequenceId.indexInBatch === 0
		? {
				sequenceNumber: brand(sequenceId.sequenceNumber - 1),
				indexInBatch: Number.POSITIVE_INFINITY,
			}
		: {
				sequenceNumber: brand(sequenceId.sequenceNumber),
				indexInBatch: sequenceId.indexInBatch - 1,
			};
};
```

### Decision procedure: `shared-tree-core/sharedTreeCore.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:1-794`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ClonableSchemaAndPolicy extends SchemaAndPolicy {
	schema: TreeStoredSchemaRepository;
}
export interface SharedTreeCoreOptionsInternal extends CodecWriteOptions {
	readonly healUnresolvableIdentifiersOnDecode?: boolean;
	readonly retainHistory?: boolean | number;
	readonly validateCommitsOnFirstSubmission?: boolean;
	readonly validateRebasedCommitsBeforeResubmission?: boolean;
}
export interface EnrichmentConfig<TChange> {
	readonly enricher: ChangeEnricher<TChange>;
	readonly resubmitMachine?: ResubmitMachine<TChange>;
}
@breakingClass
export class SharedTreeCore<
		TEditor extends ChangeFamilyEditor,
		TChange,
		TChangeProcessingContext,
	>
	extends VersionedSummarizer<SharedTreeSummaryFormatVersion>
	implements WithBreakable, Summarizable
{
	private readonly editManager: EditManager<TEditor, TChange, TChangeProcessingContext>;
	private readonly summarizables: readonly [
		EditManagerSummarizer<TChange, TChangeProcessingContext>,
		...Summarizable[],
	];
	private detachedRevision: SeqNumber | undefined = minimumPossibleSequenceNumber;
	private readonly messageCodec: IJsonCodec<
		DecodedMessage<TChange>,
		unknown,
		unknown,
		MessageEncodingContext
	>;
	private readonly enrichers: Map<BranchId, EnricherState<TChange>> = new Map();
	public readonly mintRevisionTag: () => RevisionTag;
	private readonly schemaAndPolicy: ClonableSchemaAndPolicy;
	private static readonly maxBranchNameLength = 1024;
	public constructor(
		public readonly breaker: Breakable,
		public readonly sharedObject: IChannelView & IFluidLoadable,
		public readonly serializer: IFluidSerializer,
		public readonly submitLocalMessage: (content: unknown, localOpMetadata?: unknown) => void,
		summarizables: readonly Summarizable[],
		protected readonly changeFamily: ChangeFamily<TEditor, TChange, TChangeProcessingContext>,
		private readonly coreOptions: SharedTreeCoreOptionsInternal,
		changeFormatVersionForEditManager: DependentFormatVersion<EditManagerFormatVersion>,
		changeFormatVersionForMessage: DependentFormatVersion<MessageFormatVersion>,
		protected readonly idCompressor: IIdCompressor,
		schema: TreeStoredSchemaRepository,
		schemaPolicy: SchemaPolicy,
		enrichmentConfig?: EnrichmentConfig<TChange>,
		public readonly getEditor: () => TEditor = () => this.getLocalBranch().editor,
	) {
		super(
			summarizablesTreeKey,
			minVersionToSharedTreeSummaryFormatVersion(coreOptions.minVersionForCollab),
			supportedSharedTreeSummaryFormatVersions,
			true  ,
		);
		this.schemaAndPolicy = {
			schema,
			policy: schemaPolicy,
		};
		const logger = breaker.logger;
		const rebaseLogger = createChildLogger({
			logger,
			namespace: "Rebase",
		});
		this.mintRevisionTag = () => this.idCompressor.generateCompressedId();
		const localSessionId = idCompressor.localSessionId;
		this.editManager = new EditManager(
			changeFamily,
			localSessionId,
			this.mintRevisionTag,
			(branchId) => this.registerSharedBranch(branchId),
			rebaseLogger,
		);
		this.editManager.setHistoryRetention(coreOptions.retainHistory ?? false);
		this.registerSharedBranch("main");
		const revisionTagCodec = new RevisionTagCodec(idCompressor);
		const editManagerCodec = makeEditManagerCodecBuilder<TChange>().build({
			...coreOptions,
			changeCodecs: this.editManager.changeFamily.codecs,
			dependentChangeFormatVersion: changeFormatVersionForEditManager,
			revisionTagCodec,
		});
		this.summarizables = [
			new EditManagerSummarizer(
				this.editManager,
				editManagerCodec,
				this.idCompressor,
				coreOptions.minVersionForCollab,
				this.schemaAndPolicy,
				coreOptions.healUnresolvableIdentifiersOnDecode === true
					? { sharedObjectId: sharedObject.id, logger }
					: undefined,
			),
			...summarizables,
		];
		assert(
			new Set(this.summarizables.map((e) => e.key)).size === this.summarizables.length,
			0x350  ,
		);
		this.messageCodec = makeMessageCodecBuilder<TChange>().build({
			...coreOptions,
			changeCodecs: changeFamily.codecs,
			dependentChangeFormatVersion: changeFormatVersionForMessage,
			revisionTagCodec: new RevisionTagCodec(idCompressor),
		});
		if (enrichmentConfig !== undefined) {
			this.registerSharedBranchForEditing(
				"main",
				enrichmentConfig.enricher,
				enrichmentConfig.resubmitMachine,
			);
		}
	}
	protected summarizeInternal(props: {
		stringify: SummaryElementStringifier;
		fullTree?: boolean;
		trackState?: boolean;
		telemetryContext?: ITelemetryContext;
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext;
		builder: SummaryTreeBuilder;
	}): void {
		const { stringify, fullTree, telemetryContext, incrementalSummaryContext, builder } =
			props;
		const summarizableBuilder = new SummaryTreeBuilder();
		for (const s of this.summarizables) {
			const childIncrementalSummaryContext =
				incrementalSummaryContext === undefined
					? undefined
					: {
							...incrementalSummaryContext,
							summaryPath: `${incrementalSummaryContext.summaryPath}/${summarizablesTreeKey}/${s.key}`,
						};
			summarizableBuilder.addWithStats(
				s.key,
				s.summarize({
					stringify,
					fullTree,
					telemetryContext,
					incrementalSummaryContext: childIncrementalSummaryContext,
				}),
			);
		}
		builder.addWithStats(summarizablesTreeKey, summarizableBuilder.getSummaryTree());
	}
	protected async loadInternal(
		services: IChannelStorageService,
		parse: SummaryElementParser,
	): Promise<void> {
		const [editManagerSummarizer, ...summarizables] = this.summarizables;
		const loadEditManager = this.loadSummarizable(editManagerSummarizer, services, parse);
		const loadSummarizables = summarizables.map(async (s) =>
			this.loadSummarizable(s, services, parse),
		);
		if (this.detachedRevision === undefined) {
			await Promise.all([loadEditManager, ...loadSummarizables]);
		} else {
			await loadEditManager;
			const latestDetachedSequenceNumber = this.editManager.getLatestSequenceNumber();
			if (latestDetachedSequenceNumber !== undefined && latestDetachedSequenceNumber < 0) {
				this.detachedRevision = latestDetachedSequenceNumber;
			}
			await Promise.all(loadSummarizables);
		}
	}
	@throwIfBroken
	public summarizeCore(
		serializer: IFluidSerializer,
		telemetryContext?: ITelemetryContext,
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
		fullTree?: boolean,
	): ISummaryTreeWithStats {
		return this.summarize({
			stringify: (contents: unknown) =>
				serializer.stringify(contents, this.sharedObject.handle),
			fullTree,
			telemetryContext,
			incrementalSummaryContext,
		});
	}
	public async loadCore(services: IChannelStorageService): Promise<void> {
		assert(
			this.getLocalBranch().getHead() === this.editManager.getTrunkHead("main"),
			0xaaa  ,
		);
		await super.load(services, (contents) => this.serializer.parse(contents));
	}
	private registerSharedBranch(branchId: BranchId): void {
		const branch = this.editManager.getLocalBranch(branchId);
		branch.events.on("beforeChange", (change) => {
			if (change.type === "append") {
				if (this.detachedRevision === undefined) {
					this.getCommitEnricher(branchId).prepareChanges(
						change.newCommits,
						this.coreOptions.validateCommitsOnFirstSubmission ?? false,
					);
				}
				for (const commit of change.newCommits) {
					this.submitCommit(branchId, commit, this.schemaAndPolicy, false);
				}
			}
		});
	}
	private async loadSummarizable(
		summarizable: Summarizable,
		services: IChannelStorageService,
		parse: SummaryElementParser,
	): Promise<void> {
		return summarizable.load(
			scopeStorageService(services, summarizablesTreeKey, summarizable.key),
			parse,
		);
	}
	protected submitCommit(
		branchId: BranchId,
		commit: GraphCommit<TChange>,
		schemaAndPolicy: ClonableSchemaAndPolicy,
		isResubmit: boolean,
	): void {
		assert(
			this.sharedObject.isAttached() === (this.detachedRevision === undefined),
			0x95a  ,
		);
		if (this.detachedRevision !== undefined) {
			const newRevision: SeqNumber = brand((this.detachedRevision as number) + 1);
			this.detachedRevision = newRevision;
			this.editManager.addSequencedChanges(
				[commit],
				this.editManager.localSessionId,
				newRevision,
				this.detachedRevision,
				branchId,
				false,
			);
			this.editManager.advanceMinimumSequenceNumber(newRevision, false);
			return undefined;
		}
		const enrichedCommit = isResubmit
			? commit
			: replaceChange(commit, this.getCommitEnricher(branchId).retrieveChange(commit));
		this.submitMessage(
			{
				type: "commit",
				commit: enrichedCommit,
				sessionId: this.editManager.localSessionId,
				branchId,
			},
			schemaAndPolicy,
		);
		this.getResubmitMachine(branchId).onCommitSubmitted(enrichedCommit);
	}
	protected submitBranchCreation(branchId: BranchId, branchName?: string): void {
		this.submitMessage(
			{ type: "branch", sessionId: this.editManager.localSessionId, branchId, branchName },
			this.schemaAndPolicy,
		);
	}
	private submitMessage(
		message: DecodedMessage<TChange>,
		schemaAndPolicy: ClonableSchemaAndPolicy,
	): void {
		const encodedMessage = this.messageCodec.encode(message, {
			idCompressor: this.idCompressor,
			schema: schemaAndPolicy,
		});
		this.submitLocalMessage(encodedMessage, {
			schema: schemaAndPolicy.schema.clone(),
			policy: schemaAndPolicy.policy,
		});
	}
	public processMessagesCore(messagesCollection: IRuntimeMessageCollection): void {
		const { envelope, local, messagesContent } = messagesCollection;
		const commits: GraphCommit<TChange>[] = [];
		let messagesSessionId: SessionId | undefined;
		let branchId: BranchId | undefined;
		const processBunch = (branch: BranchId): void => {
			assert(messagesSessionId !== undefined, 0xada  );
			this.processCommits(
				messagesSessionId,
				brand(envelope.sequenceNumber),
				brand(envelope.referenceSequenceNumber),
				local,
				branch,
				commits,
			);
			commits.length = 0;
			branchId = undefined;
		};
		for (const messageContent of messagesContent) {
			const message = this.messageCodec.decode(messageContent.contents, {
				idCompressor: this.idCompressor,
			});
			if (messagesSessionId !== undefined) {
				assert(
					messagesSessionId === message.sessionId,
					0xad9  ,
				);
			}
			messagesSessionId = message.sessionId;
			const type = message.type;
			switch (type) {
				case "commit": {
					if (branchId !== undefined && message.branchId !== branchId) {
						processBunch(branchId);
					}
					branchId = message.branchId;
					commits.push(message.commit);
					break;
				}
				case "branch": {
					if (branchId !== undefined) {
						processBunch(branchId);
					}
					this.editManager.sequenceBranchCreation(
						messagesSessionId,
						brand(envelope.referenceSequenceNumber),
						message.branchId,
						message.branchName,
					);
					break;
				}
				default: {
					unreachableCase(type);
				}
			}
		}
		if (branchId !== undefined) {
			processBunch(branchId);
		}
		this.editManager.advanceMinimumSequenceNumber(brand(envelope.minimumSequenceNumber));
	}
	private processCommits(
		sessionId: SessionId,
		sequenceNumber: SeqNumber,
		referenceSequenceNumber: SeqNumber,
		isLocal: boolean,
		branchId: BranchId,
		commits: readonly GraphCommit<TChange>[],
	): void {
		this.editManager.addSequencedChanges(
			commits,
			sessionId,
			sequenceNumber,
			referenceSequenceNumber,
			branchId,
		);
		for (const commit of commits) {
			this.tryGetResubmitMachine(branchId)?.onSequencedCommitApplied(commit.revision, isLocal);
		}
	}
	public getLocalBranch(): SharedTreeBranch<TEditor, TChange, TChangeProcessingContext> {
		return this.editManager.getLocalBranch("main");
	}
	public getTrunkHead(): GraphCommit<TChange> {
		return this.editManager.getTrunkHead("main");
	}
	public getSharedBranchIds(): string[] {
		return this.editManager
			.getSharedBranchIds()
			.filter((id): id is SessionSpaceCompressedId => id !== "main")
			.map((id) => this.idCompressor.decompress(id));
	}
	public createSharedBranch(branchName?: string): string {
		if (branchName !== undefined && branchName.length > SharedTreeCore.maxBranchNameLength) {
			throw new UsageError(
				`Branch name is too long: ${branchName.length} > maxBranchNameLength`,
			);
		}
		const branchId = this.idCompressor.generateCompressedId();
		this.addBranch(branchId, branchName);
		this.submitBranchCreation(branchId, branchName);
		return this.idCompressor.decompress(branchId);
	}
	protected addBranch(branchId: BranchId, branchName?: string): void {
		this.editManager.addNewBranch(branchId, branchName);
	}
	public getSharedBranch(
		branchId: BranchId,
	): SharedTreeBranch<TEditor, TChange, TChangeProcessingContext> {
		return this.editManager.getLocalBranch(branchId);
	}
	public getSharedBranchName(branchId: string): string | undefined {
		const compressedId = this.idCompressor.tryRecompress(branchId as StableId);
		if (compressedId === undefined) {
			throw new UsageError(`No branch found with id: ${branchId}`);
		}
		return this.editManager.getSharedBranchName(compressedId);
	}
	public didAttach(): void {
		this.detachedRevision = undefined;
	}
	public reSubmitCore(content: JsonCompatibleReadOnly, localOpMetadata: unknown): void {
		const message = this.messageCodec.decode(this.serializer.decode(content), {
			idCompressor: this.idCompressor,
		});
		const type = message.type;
		switch (type) {
			case "commit": {
				const {
					commit: { revision },
					branchId,
				} = message;
				const resubmitMachine = this.getResubmitMachine(branchId);
				const getLocalCommits = (): GraphCommit<TChange>[] => {
					const localCommits = this.editManager.getLocalCommits(branchId);
					const revisionIndex = localCommits.findIndex((c) => c.revision === revision);
					assert(revisionIndex >= 0, 0xbdb  );
					return localCommits.slice(revisionIndex);
				};
				assert(
					isClonableSchemaPolicy(localOpMetadata),
					0x95e  ,
				);
				const enrichedCommit = resubmitMachine.getEnrichedCommit(revision, getLocalCommits);
				if (enrichedCommit !== undefined) {
					this.submitCommit(branchId, enrichedCommit, localOpMetadata, true);
				}
				break;
			}
			case "branch": {
				this.submitBranchCreation(message.branchId, message.branchName);
				break;
			}
			default: {
				unreachableCase(type);
			}
		}
	}
	public rollback(content: JsonCompatibleReadOnly, localOpMetadata: unknown): void {
		const message = this.messageCodec.decode(this.serializer.decode(content), {
			idCompressor: this.idCompressor,
		});
		const type = message.type;
		switch (type) {
			case "commit": {
				const {
					commit: { revision },
					branchId,
				} = message;
				const branch = this.editManager.getLocalBranch(branchId);
				const head = branch.getHead();
				assert(head.revision === revision, 0xc6b  );
				const newHead = head.parent ?? fail(0xc6c  );
				branch.removeAfter(newHead);
				this.getResubmitMachine(branchId).onCommitRollback(head);
				break;
			}
			case "branch": {
				this.editManager.removeBranch(message.branchId);
				break;
			}
			default: {
				unreachableCase(type);
			}
		}
	}
	public applyStashedOp(content: JsonCompatibleReadOnly): void {
		const message = this.messageCodec.decode(this.serializer.decode(content), {
			idCompressor: this.idCompressor,
		});
		const type = message.type;
		switch (type) {
			case "commit": {
				const {
					commit: { revision, change, customMetadata },
					branchId,
				} = message;
				this.editManager
					.getLocalBranch(branchId)
					.apply({ change, revision }, CommitKind.Default, customMetadata);
				break;
			}
			case "branch": {
				this.editManager.addNewBranch(message.branchId, message.branchName);
				break;
			}
			default: {
				unreachableCase(type);
			}
		}
	}
	protected registerSharedBranchForEditing(
		branchId: BranchId,
		enricher: ChangeEnricher<TChange>,
		resubmitMachine?: ResubmitMachine<TChange>,
	): void {
		const commitEnricher = new BranchCommitEnricher(enricher);
		assert(!this.enrichers.has(branchId), 0xc6d  );
		this.enrichers.set(branchId, {
			enricher: commitEnricher,
			resubmitMachine:
				resubmitMachine ??
				new DefaultResubmitMachine(
					enricher,
					this.coreOptions.validateRebasedCommitsBeforeResubmission ?? false,
				),
		});
	}
	private getResubmitMachine(branchId: BranchId): ResubmitMachine<TChange> {
		return this.getEnricherState(branchId).resubmitMachine;
	}
	private tryGetResubmitMachine(branchId: BranchId): ResubmitMachine<TChange> | undefined {
		return this.tryGetEnricherState(branchId)?.resubmitMachine;
	}
	public getCommitEnricher(branchId: BranchId): BranchCommitEnricher<TChange> {
		return this.getEnricherState(branchId).enricher;
	}
	private getEnricherState(branchId: BranchId): EnricherState<TChange> {
		return (
			this.tryGetEnricherState(branchId) ??
			fail(0xc6e  )
		);
	}
	private tryGetEnricherState(branchId: BranchId): EnricherState<TChange> | undefined {
		return this.enrichers.get(branchId);
	}
}
interface EnricherState<TChange> {
	readonly enricher: BranchCommitEnricher<TChange>;
	readonly resubmitMachine: ResubmitMachine<TChange>;
}
function isClonableSchemaPolicy(
	maybeSchemaPolicy: unknown,
): maybeSchemaPolicy is ClonableSchemaAndPolicy {
	const schemaAndPolicy = maybeSchemaPolicy as ClonableSchemaAndPolicy;
	return schemaAndPolicy.schema !== undefined && schemaAndPolicy.policy !== undefined;
}
function scopeStorageService(
	service: IChannelStorageService,
	...pathElements: string[]
): IChannelStorageService {
	const scope = `${pathElements.join("/")}/`;
	return {
		async readBlob(path: string): Promise<ArrayBufferLike> {
			return service.readBlob(`${scope}${path}`);
		},
		async contains(path) {
			return service.contains(`${scope}${path}`);
		},
		async list(path) {
			return service.list(`${scope}${path}`);
		},
		getSnapshotTree(): ISnapshotTree | undefined {
			const snapshotTree = service.getSnapshotTree();
			if (snapshotTree === undefined) {
				return undefined;
			}
			let scopedTree = snapshotTree;
			for (const element of pathElements) {
				const tree = scopedTree.trees[element];
				assert(
					tree !== undefined,
					0xc20  ,
				);
				scopedTree = tree;
			}
			return scopedTree;
		},
	};
}
```

### Decision procedure: `shared-tree-core/transaction.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/transaction.ts:1-686`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
interface MutableCustomMetadataTree {
	metadata: JsonCompatibleReadOnlyObject | undefined;
	children: MutableCustomMetadataTree[];
}
export enum TransactionResult {
	Abort,
	Commit,
}
export interface Transactor<TOptions> {
	start(options?: TOptions): void;
	commit(): void;
	abort(): void;
	size: number;
	events: Listenable<TransactionEvents>;
}
export interface TransactionEvents {
	started(): void;
	aborting(): void;
	aborted(): void;
	committing(): void;
}
export interface Callbacks<TOptions> {
	readonly onPop?: OnPop;
	readonly onPush?: OnPush<TOptions>;
}
export type OnPush<TOptions> = (options?: TOptions) => Callbacks<TOptions> | void;
export type OnPop = (result: TransactionResult) => void;
interface TransactionStackFrame<TOptions> {
	readonly callbacks: Callbacks<TOptions>;
}
export class TransactionStack<TOptions> implements Transactor<TOptions>, IDisposable {
	readonly #stack: TransactionStackFrame<TOptions>[] = [];
	readonly #onPush?: OnPush<TOptions>;
	readonly #events = createEmitter<TransactionEvents>();
	public get events(): Listenable<TransactionEvents> {
		return this.#events;
	}
	#disposed = false;
	public get disposed(): boolean {
		return this.#disposed;
	}
	public constructor(onPush?: OnPush<TOptions>) {
		this.#onPush = onPush;
	}
	public get size(): number {
		this.ensureNotDisposed();
		return this.#stack.length;
	}
	public start(options?: TOptions): void {
		this.ensureNotDisposed();
		const last = getLast(this.#stack);
		const onPushCurrent = last === undefined ? this.#onPush : last.callbacks.onPush;
		const { onPush, onPop } = onPushCurrent?.(options) ?? {};
		this.#stack.push({
			callbacks: { onPop, onPush: onPush ?? onPushCurrent },
		});
		this.#events.emit("started");
	}
	public commit(): void {
		this.ensureNotDisposed();
		if (this.size === 0) {
			throw new UsageError("No transaction to commit");
		}
		this.#events.emit("committing");
		this.#stack.pop()?.callbacks.onPop?.(TransactionResult.Commit);
	}
	public abort(): void {
		this.ensureNotDisposed();
		if (this.size === 0) {
			throw new UsageError("No transaction to abort");
		}
		this.#events.emit("aborting");
		this.#stack.pop()?.callbacks.onPop?.(TransactionResult.Abort);
		this.#events.emit("aborted");
	}
	public dispose(): void {
		this.ensureNotDisposed();
		while (this.size > 0) {
			this.abort();
		}
		this.#disposed = true;
	}
	private ensureNotDisposed(): void {
		if (this.disposed) {
			throw new UsageError("Transactor is disposed");
		}
	}
}
export type OnPopWithViewUpdate<TChange> = (
	result: TransactionResult,
	viewUpdate: TChange | undefined,
) => void;
export enum ChangeProcessorApplicability {
	IfOutermost,
	Always,
}
export interface ChangeProcessor<TChange, TChangeProcessingContext> {
	readonly applicability: ChangeProcessorApplicability;
	readonly processChange: ProcessChangeFn<TChange, TChangeProcessingContext>;
}
export interface SquashingTransactionOptions<TChange, TChangeProcessingContext> {
	readonly postProcessor?: ChangeProcessor<TChange, TChangeProcessingContext>;
	readonly customMetadata?: JsonCompatibleReadOnlyObject;
}
export class SquashingTransactionStack<
	TEditor extends ChangeFamilyEditor,
	TChange,
	TChangeProcessingContext,
> extends TransactionStack<SquashingTransactionOptions<TChange, TChangeProcessingContext>> {
	#transactionBranch?: SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>;
	public readonly activeBranchEditor = new Proxy<TEditor>({} as unknown as TEditor, {
		get: (_, p, receiver) => {
			return Reflect.get(this.activeBranch.editor, p, receiver);
		},
	});
	public get activeBranch(): SharedTreeBranch<TEditor, TChange, TChangeProcessingContext> {
		return this.#transactionBranch ?? this.branch;
	}
	public get activeBranchEvents(): Listenable<
		SharedTreeBranchEvents<TEditor, TChange, TChangeProcessingContext>
	> {
		const off = (
			eventName: keyof SharedTreeBranchEvents<TEditor, TChange, TChangeProcessingContext>,
			listener: SharedTreeBranchEvents<
				TEditor,
				TChange,
				TChangeProcessingContext
			>[typeof eventName],
		): void => {
			this.activeBranch.events.off(eventName, listener);
			const listeners = this.#activeBranchEvents.get(eventName);
			if (listeners?.delete(listener) === true && listeners.size === 0) {
				this.#activeBranchEvents.delete(eventName);
			}
		};
		return {
			on: (eventName, listener) => {
				const listeners = getOrCreate(this.#activeBranchEvents, eventName, () => new Set());
				listeners.add(listener);
				this.activeBranch.events.on(eventName, listener);
				return () => off(eventName, listener);
			},
			off,
		};
	}
	readonly #activeBranchEvents = new Map<
		keyof SharedTreeBranchEvents<TEditor, TChange, TChangeProcessingContext>,
		Set<
			SharedTreeBranchEvents<
				TEditor,
				TChange,
				TChangeProcessingContext
			>[keyof SharedTreeBranchEvents<TEditor, TChange, TChangeProcessingContext>]
		>
	>();
	public constructor(
		public readonly branch: SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>,
		mintRevisionTag: () => RevisionTag,
		onPush?: () => OnPopWithViewUpdate<TChange> | void,
	) {
		const postProcessorStack: (
			| ChangeProcessor<TChange, TChangeProcessingContext>
			| undefined
		)[] = [];
		const resolvePostProcessor = (
			requested: ChangeProcessor<TChange, TChangeProcessingContext> | undefined,
		): ChangeProcessor<TChange, TChangeProcessingContext> | undefined => {
			if (
				requested?.applicability === ChangeProcessorApplicability.IfOutermost &&
				postProcessorStack.includes(requested)
			) {
				return undefined;
			}
			return requested;
		};
		super(
			(
				startOptions?: SquashingTransactionOptions<TChange, TChangeProcessingContext>,
			): Callbacks<SquashingTransactionOptions<TChange, TChangeProcessingContext>> => {
				postProcessorStack.push(resolvePostProcessor(startOptions?.postProcessor));
				const rootMetadataNode: MutableCustomMetadataTree = {
					metadata: startOptions?.customMetadata,
					children: [],
				};
				let openMetadataNode = rootMetadataNode;
				const hasCustomMetadata = (node: CustomMetadataTree): boolean =>
					node.metadata !== undefined || node.children.some(hasCustomMetadata);
				const startHead = this.activeBranch.getHead();
				const changeFamily = this.branch.changeFamily;
				const rebaser = changeFamily.rebaser;
				const outerOnPop = onPush?.();
				let transactionRevision: RevisionTag | undefined;
				const transactionBranch = this.branch.fork(
					startHead,
					() => (transactionRevision ??= mintRevisionTag()),
				);
				this.setTransactionBranch(transactionBranch);
				transactionBranch.editor.enterTransaction();
				const onOuterTransactionPop: OnPop = (result) => {
					assert(this.size === 0, 0xcae  );
					const postProcessor = postProcessorStack.pop();
					transactionBranch.editor.exitTransaction();
					const sourcePath: GraphCommit<TChange>[] = [];
					const targetPath: GraphCommit<TChange>[] = [];
					const ancestor = findCommonAncestor(
						[startHead, sourcePath],
						[branch.getHead(), targetPath],
					);
					assert(ancestor !== undefined, 0xcce  );
					const transactionSteps: GraphCommit<TChange>[] = [];
					findAncestor(
						[transactionBranch.getHead(), transactionSteps],
						(c) => c === startHead,
					);
					let viewUpdate: TChange | undefined;
					switch (result) {
						case TransactionResult.Abort: {
							transactionBranch.removeAfter(startHead);
							if (targetPath.length > 0) {
								viewUpdate = diffHistories(
									rebaser,
									startHead,
									this.branch.getHead(),
									mintRevisionTag,
								);
							}
							break;
						}
						case TransactionResult.Commit: {
							if (transactionSteps.length > 0) {
								assert(
									transactionRevision !== undefined,
									0xccf  ,
								);
								for (const commit of transactionSteps) {
									assert(
										commit.revision === transactionRevision,
										0xcaf  ,
									);
								}
								const squash = rebaser.compose(transactionSteps);
								cheapRebaseValidation("Malformed composed transaction", () =>
									changeFamily.validator(squash),
								);
								const change =
									postProcessor === undefined
										? squash
										: changeFamily.buildProcessor(postProcessor.processChange)(squash);
								if (change !== squash) {
									transactionBranch.removeAfter(startHead);
									transactionBranch.apply(
										tagChange(change, transactionRevision),
										CommitKind.Default,
										undefined,
									);
								}
								const customMetadata = hasCustomMetadata(rootMetadataNode)
									? rootMetadataNode
									: undefined;
								if (targetPath.length === 0) {
									this.branch.apply(
										tagChange(change, transactionRevision),
										CommitKind.Default,
										customMetadata,
									);
								} else {
									const unrebasedHead = mintCommit(startHead, {
										change,
										revision: transactionRevision,
										customMetadata,
									});
									const rebased = rebaseBranch(
										mintRevisionTag,
										changeFamily,
										unrebasedHead,
										branch.getHead(),
										branch.getHead(),
									);
									assert(
										rebased.newSourceHead.revision === transactionRevision,
										0xcd0  ,
									);
									this.branch.apply(rebased.newSourceHead, CommitKind.Default, customMetadata);
									viewUpdate = rebased.sourceChange;
								}
							} else {
								if (targetPath.length > 0) {
									viewUpdate = diffHistories(
										rebaser,
										startHead,
										this.branch.getHead(),
										mintRevisionTag,
									);
								}
							}
							break;
						}
						default: {
							unreachableCase(result);
						}
					}
					transactionBranch.dispose();
					this.setTransactionBranch(undefined);
					outerOnPop?.(result, viewUpdate);
				};
				const onNestedTransactionPush: OnPush<
					SquashingTransactionOptions<TChange, TChangeProcessingContext>
				> = (nestedStartOptions) => {
					postProcessorStack.push(resolvePostProcessor(nestedStartOptions?.postProcessor));
					const nestedMetadataNode: MutableCustomMetadataTree = {
						metadata: nestedStartOptions?.customMetadata,
						children: [],
					};
					const metadataParent = openMetadataNode;
					metadataParent.children.push(nestedMetadataNode);
					openMetadataNode = nestedMetadataNode;
					const nestedStartHead = this.activeBranch.getHead();
					const nestedOuterOnPop = onPush?.();
					transactionBranch.editor.enterTransaction();
					return {
						onPop: (result) => {
							const nestedPostProcessor = postProcessorStack.pop();
							openMetadataNode = metadataParent;
							transactionBranch.editor.exitTransaction();
							switch (result) {
								case TransactionResult.Abort: {
									metadataParent.children.pop();
									transactionBranch.removeAfter(nestedStartHead);
									break;
								}
								case TransactionResult.Commit: {
									if (nestedPostProcessor !== undefined) {
										const nestedSteps: GraphCommit<TChange>[] = [];
										findAncestor(
											[transactionBranch.getHead(), nestedSteps],
											(c) => c === nestedStartHead,
										);
										if (nestedSteps.length > 0) {
											assert(
												transactionRevision !== undefined,
												0xd07  ,
											);
											const squash = rebaser.compose(nestedSteps);
											const processedSquash = changeFamily.buildProcessor(
												nestedPostProcessor.processChange,
											)(squash);
											if (processedSquash !== squash) {
												transactionBranch.removeAfter(nestedStartHead);
												transactionBranch.apply(
													tagChange(processedSquash, transactionRevision),
													CommitKind.Default,
													undefined,
												);
											}
										}
									}
									break;
								}
								default: {
									unreachableCase(result);
								}
							}
							nestedOuterOnPop?.(result, undefined);
						},
					};
				};
				return { onPop: onOuterTransactionPop, onPush: onNestedTransactionPush };
			},
		);
	}
	private setTransactionBranch(
		transactionBranch:
			| SharedTreeBranch<TEditor, TChange, TChangeProcessingContext>
			| undefined,
	): void {
		const oldActiveBranch = this.activeBranch;
		this.#transactionBranch = transactionBranch;
		for (const [eventName, listeners] of this.#activeBranchEvents) {
			for (const listener of listeners) {
				oldActiveBranch.events.off(eventName, listener);
				this.activeBranch.events.on(eventName, listener);
			}
		}
	}
}
```

### Decision procedure: `shared-tree-core/versionedSummarizer.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/versionedSummarizer.ts:1-120`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export abstract class VersionedSummarizer<TVersion extends number> implements Summarizable {
	public constructor(
		public readonly key: string,
		private readonly writeVersion: TVersion,
		private readonly supportedVersions: ReadonlySet<TVersion>,
		private readonly supportPreVersioningFormat: boolean,
	) {
		assert(
			this.supportedVersions.has(this.writeVersion),
			0xca6  ,
			() => `Write version ${this.writeVersion} requested but not supported with key ${key}.`,
		);
	}
	protected abstract summarizeInternal(props: {
		stringify: SummaryElementStringifier;
		fullTree?: boolean;
		trackState?: boolean;
		telemetryContext?: ITelemetryContext;
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext;
		builder: SummaryTreeBuilder;
	}): void;
	protected abstract loadInternal(
		services: IChannelStorageService,
		parse: SummaryElementParser,
		version: TVersion | undefined,
	): Promise<void>;
	public summarize(props: {
		stringify: SummaryElementStringifier;
		fullTree?: boolean;
		trackState?: boolean;
		telemetryContext?: ITelemetryContext;
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext;
	}): ISummaryTreeWithStats {
		const builder = new SummaryTreeBuilder();
		const metadata: SharedTreeSummarizableMetadata = {
			version: this.writeVersion,
		};
		builder.addBlob(summarizablesMetadataKey, props.stringify(metadata));
		this.summarizeInternal({ ...props, builder });
		return builder.getSummaryTree();
	}
	public async load(
		services: IChannelStorageService,
		parse: SummaryElementParser,
	): Promise<void> {
		let version: TVersion | undefined;
		if (await services.contains(summarizablesMetadataKey)) {
			const metadata = (await readAndParseSnapshotBlob(
				summarizablesMetadataKey,
				services,
				(contents) => parse(contents),
			)) as SharedTreeSummarizableMetadata;
			version = metadata.version as TVersion;
			if (!this.supportedVersions.has(version)) {
				throw new UsageError(`Cannot read version ${version} of shared tree summary.`);
			}
		} else if (!this.supportPreVersioningFormat) {
			throw new UsageError(`Cannot read summary without versioning for shared tree summary.`);
		}
		await this.loadInternal(services, parse, version);
	}
}
```

## 5. Invariants and asserts

0xa49 revision required,0xa83/a86 nonempty rebase/merge result,0xa84 remove target ancestor.0x476 MSN regression,0xa64 outdated sequence,0x6b5 local ack with no optimistic commit,0x746 requested sequence evicted,0x744 sequence map size=trunk+sentinel,0x745 metadata size=trunk.0x68a/0x42c nonempty load;0xc68/c69 stable message only main commits.0xc6a experimental commit revision required.0xabc previous-sequence bound cannot receive infinity. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:247` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:368` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:888` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sequenceIdUtils.ts:33`

Unknown summary metadata version throws UsageError; unsupported pre-versioning when not enabled also throws.0xca6 unsupported writer layout. Resubmit stale prefix consistency asserts0xc79; missing pending0xc7a. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/versionedSummarizer.ts:99` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/defaultResubmitMachine.ts:68`

## 6. JS-semantics hazards

Do not use a Swift Int field for internal index∞: it is a lookup sentinel, never serialize it. Missing batch index and explicit0 compare equal; missing stays omitted in output. Commits and branches use reference identity for common ancestors/fast paths; equal revisions do not imply interchangeable graph nodes. Lazy cached event change preserves synchronous event ordering and avoids duplicate composition/ID allocation. Peer maps/metadata children arrays retain source order. Compressor originator belongs to each op/commit, not decoder process. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sequenceIdUtils.ts:16` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:444` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecsCommons.ts:131`

## 7. Test assets to reuse

Reuse shared-tree-core branch/transaction/message codecs and edit-manager tests, summary/codec-tree/op-format snapshots. Include repeated same-seq batches, own ack after remote rebase, out-of-date peer reference, reconnect after detached-root collection, pinned local forks, historyN trimming, stale schema on peer, customMetadata v7, shared branch summaries. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/shared-tree-core/branch.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/shared-tree-core/edit-manager/editManager.spec.ts:1`

## 8. Open questions

None for registered message/history formats. SharedTree change-family schema conflict semantics and checkout transaction UX belong to companion shared-tree spec; this file specifies generic graph and storage behavior.

