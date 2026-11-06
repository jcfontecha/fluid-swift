# Index — Fluid Framework 3.11.0

## 1. Role

`@fluidframework/tree` is one package with several internal layers, not one CRDT algorithm. `SharedTree` wires runtime services, edit-history, forest, stored schema and summary components; `TreeCheckout` is the mutable local view over a branch and these indexes. The simple-tree/public API translates application edits into this machinery. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:209` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:280`

## 2. Surface used by other packages

Layer map (dependency direction is downward):

| Layer | Responsibility | Spec owner/file |
| --- | --- | --- |
| entrypoints, api.ts, componentApi.ts, simple-tree | release-tag exports, schema factories, proxies, events, views | companion agent |
| shared-tree | change union (schema/data), checkout, transactions, runtime assembly | companion agent |
| shared-tree-core | branches, sequenced trunk, peers, reconnect/resubmit, summary history | [shared-tree-core.md](shared-tree-core.md) |
| feature-libraries/modular-schema | routes node/field changes, constraints, cross-field effects | [modular-schema.md](modular-schema.md) |
| sequence-field, optional-field, default-schema | field-specific algebra and edit construction | matching files here |
| chunked-forest, object-forest | indexed tree storage and synchronous cursors | matching files here |
| schema-index, forest-summary, node-identifier, schema-edits | persistence and supporting indexes | matching files here |
| core | revision/atom IDs, schema, cursor, delta visitor, anchors, detached roots | [core.md](core.md) |
| codec, util | version dispatch, JSON validation, ID decoding, ordered collections | companion codec spec; source citations below |
| text | text domain and encoding consumers | companion agent |
| treeFactory.ts, treeDataStore.ts, sharedTreeAttributes.ts | runtime factory, datastore integration and channel identity | companion shared-tree/public API scope |
| extrinsic-locations, sandboxing, external-utilities | externally referenced tree locations, isolation APIs, dependency adapters | package integration; not additional field algebras |
| jsonDomainSchema.ts, serializableDomainSchema.ts, tableSchema.ts, extensibleUnionNode.ts | packaged domain schemas and extensible union support | public/simple-tree consumers |
| test | fuzz models, algebra suites, codec and summary goldens | reuse as oracle assets |

The source barrels enumerate the actual internal surfaces. Flex-tree sits between forest/anchors and the simple-tree view, and indexing/comparison-forest are supporting feature libraries, not alternative op formats. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/index.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/index.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/index.ts:6`

### Ownership, boundaries and port order

The public package entrypoints are generated release-tag surfaces; internal folder exports are not a second public API. `treeFactory.ts` creates the channel factory; `treeDataStore.ts` supplies datastore integration. Root domain schemas consume the simple-tree layer. Extrinsic-locations and sandboxing add reference/isolation APIs around views; they do not introduce another op sequencer. `reference/fluidframework-3.11.0/packages/dds/tree/src/entrypoints/public.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/treeFactory.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/treeDataStore.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/extrinsic-locations/index.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/index.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/jsonDomainSchema.ts:1`

Implement core identities/cursors/schema/delta first; then field algebras under ModularChangeFamily; then a forest and its summary/index components; then branch graph + EditManager + runtime submission. Simple-tree wraps the resulting checkout rather than maintaining a parallel mutable tree. Forest content, detached-root identities, stored schema, and retained peer history must reload together: none can be regenerated solely from the visible document. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerSummarizer.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/detachedFieldIndexSummarizer.ts:1`

The area files include literal format declarations/encoders and full algorithm decision procedures, with source ranges. Those procedures define the cases and execution order; prose tables are navigation, not permission to omit a branch. No runtime code, builds, dependencies, or git state are changed by these specifications.

## 3. Wire and persisted formats

There are THREE independent version axes: summary-component layout (`.metadata`), payload codec version, and the dependent unversioned field codec selected by its parent. Never infer one from another. The default minimum collaboration version is 2.0; codec writers choose newest compatible stable format, unless explicitly overridden. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:756` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:581`

| minVersionForCollab | message / edit-manager | shared-tree / modular change | sequence | optional/required | schema | detached index | field batch | forest payload / layout |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | 3 | 3 | 2 | 2 | 1 | 1 | 1 | 1 / 2 |
| 2.43 | 4 | 4 | 3 | 2 | 2 | 1 | 1 | 1 / 2 |
| 2.52 | 4 | 4 | 3 | 2 | 2 | 2 | 1 | 1 / 2 |
| 2.73 | 4 | 4 | 3 | 2 | 2 | 2 | 2 | 1 / 2 |
| 2.74 | 4 | 4 | 3 | 2 | 2 | 2 | 2 | 2 / 3 |
| 2.80 | 6 | 5 | 3 | 2 | 2 | 2 | 2 | 2 / 3 |
| 2.117 | 7 | 5 | 3 | 2 | 2 | 2 | 2 | 2 / 3 |

Sources (the executable registrations, not version comments): `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecs.ts:86` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecs.ts:71` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:538` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:107` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:100` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecs.ts:22` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:319` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:76` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryTypes.ts:21`

The override map is keyed by codec name (Message, EditManager, Schema, DetachedFieldIndex, FieldBatch, Forest). A requested format must be registered. Without `allowPossiblyIncompatibleWriteVersionOverrides:true`, its minimum collaboration version must be defined and no newer than the configured minimum; otherwise construction throws UsageError. Automatic selection ignores entries with undefined minimum and chooses the latest compatible stable entry. Read dispatch uses each incoming version, not the chosen writer version. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/versioned/codec.ts:580-640`

Experimental message/edit-manager `"shared-branches|v0.2"` uses change/modular 4, not 5; field-batch `"text"` adds specialized shapes. Neither is selected automatically by a minimum client version. Missing/1/2 message versions and edit-manager 1/2, plus both version 5s, are discontinued error codecs, NOT readers to implement as legacy success paths. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/messageCodecs.ts:88` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManagerCodecs.ts:72` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:340`

## 4. Behavior

Local path: editor produces tagged change → branch emits `beforeChange` → updates commit head → emits `afterChange`; checkout consumes the effective change as delta to update forest/anchors/indexes; runtime submission encodes the logical change, not delta. Remote path: decode op using originator ID context → sequence through EditManager's peer branch/trunk → rebase optimistic local branch → apply resulting branch change. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:247` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:888` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:371` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:497`

Delta is a derived state transition with explicit build/detach/attach/rename/destroy phases, not the rebasable edit format. Undo is a new intention-preserving inverse; rollback restores IDs for branch rebasing/transaction abort. These are deliberately different operations. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/visitDelta.ts:40` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/invert.ts:96` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:277`

## 5. Invariants and asserts

Keep a single serial executor around a container; synchronous branch/forest callbacks are part of correctness. A retained graph fork bounds history collection. A cursor is not a stable node identity: persist an anchor, then reacquire a cursor after edits. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:270` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/editManager.ts:391` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/forest/editableForest.ts:26`

## 6. JS-semantics hazards

All codecs below require FluidJS ordering and omission semantics. In particular `null` is meaningful in optional registers and experimental shape overrides; it cannot stand in for missing. ID-compressor session-space and op-space numbers are not interchangeable, even when both happen to be integers. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/changeAtomIdCodec.ts:24` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecV2.ts:35` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:177`

## 7. Test assets to reuse

Reuse the source test tree's core/tree, rebase, shared-tree-core/edit-manager, feature-libraries field suites, and snapshots. Snapshot families include `op-format`, `codec-tree`, `codecFormats`, `summary`, `sequence-field`, `optional-field`, `detached-field-index` and `chunked-forest-schema-compressed`. See the concrete test entrypoints cited in each area spec.

## 8. Open questions

None for layer ownership. Companion specs cover public API, simple-tree, shared-tree change union, general codec infrastructure, and text; this index does not replace those specs.

