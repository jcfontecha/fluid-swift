# runtime-definitions — native Swift port contract (3.11.0)

## 1. Role

The shared boundary between container runtime, datastore context/runtime, summarizer nodes and DDS-facing services. Most exports are declarations, not implementations: do not invent transport messages, persistence, default values or event emission merely because a member exists. The package also defines literal routing/GC names and numeric enums. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/index.ts:1-115`

## 2. Surface used by other packages

The complete boundary declarations below include the context's parent services, channel control, factories/registries, message collections, summary callbacks/results, GC, attribution, version marks and extension compatibility. `readonly` restricts callers, not runtime object mutability; optional members require capability checks. Interface/type brands are not encoded fields. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/index.ts:1-115`

### dataStoreContext: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export enum FlushMode {
	Immediate,
	TurnBased,
}
export const VisibilityState = {
	NotVisible: "NotVisible",
	LocallyVisible: "LocallyVisible",
	GloballyVisible: "GloballyVisible",
};
export type VisibilityState = (typeof VisibilityState)[keyof typeof VisibilityState];
export interface IContainerRuntimeBaseEvents extends IEvent {
	(event: "batchBegin", listener: (op: Omit<ISequencedDocumentMessage, "contents">) => void);
	(
		event: "batchEnd",
		listener: (error: unknown, op: Omit<ISequencedDocumentMessage, "contents">) => void,
	);
	(event: "op", listener: (op: ISequencedDocumentMessage, runtimeMessage?: boolean) => void);
	(event: "signal", listener: (message: IInboundSignalMessage, local: boolean) => void);
	(event: "dispose", listener: () => void);
	(event: "stagingModeChanged", listener: (stagingModeInfo: StagingModeChangedEvent) => void);
	(event: "hasStagedChangesChanged", listener: (hasStagedChanges: boolean) => void);
}
export type AliasResult = "Success" | "Conflict" | "AlreadyAliased";
export interface IDataStore {
	trySetAlias(alias: string): Promise<AliasResult>;
	readonly entryPoint: IFluidHandleInternal<FluidObject>;
}
export interface StageControls {
	readonly commitChanges: () => void;
	readonly discardChanges: () => void;
}
export interface IContainerRuntimeBase extends IEventProvider<IContainerRuntimeBaseEvents> {
	readonly baseLogger: ITelemetryBaseLogger;
	readonly clientDetails: IClientDetails;
	readonly disposed: boolean;
	readonly versionMarkResolver: IVersionMarkResolver;
	orderSequentially(callback: () => void): void;
	submitSignal: (type: string, content: unknown, targetClientId?: string) => void;
	createDataStore(pkg: string | PackagePath, loadingGroupId?: string): Promise<IDataStore>;
	createDetachedDataStore(
		pkg: readonly string[],
		loadingGroupId?: string,
	): IFluidDataStoreContextDetached;
	getAliasedDataStoreEntryPoint(alias: string): Promise<IFluidHandle<FluidObject> | undefined>;
	getAbsoluteUrl(relativeUrl: string): Promise<string | undefined>;
	uploadBlob(
		blob: ArrayBufferLike,
		signal?: AbortSignal,
	): Promise<IFluidHandle<ArrayBufferLike>>;
	getQuorum(): IQuorumClients;
	getAudience(): IAudience;
	generateDocumentUniqueId(): number | string;
	getSnapshotForLoadingGroupId(
		loadingGroupIds: string[],
		pathParts: string[],
	): Promise<{ snapshotTree: ISnapshotTree; sequenceNumber: number }>;
	enterStagingMode(): StageControls;
	readonly inStagingMode: boolean;
	readonly hasStagedChanges: boolean;
}
export interface IFluidDataStorePolicies {
	readonly readonlyInStagingMode: boolean;
}
export interface IFluidDataStoreChannel extends IDisposable {
	readonly policies?: IFluidDataStorePolicies;
	makeVisibleAndAttachGraph(): void;
	getAttachSummary(telemetryContext?: ITelemetryContext): ISummaryTreeWithStats;
	getAttachGCData(telemetryContext?: ITelemetryContext): IGarbageCollectionData;
	processMessages(messageCollection: IRuntimeMessageCollection): void;
	processSignal(message: IInboundSignalMessage, local: boolean): void;
	summarize(
		fullTree?: boolean,
		trackState?: boolean,
		telemetryContext?: ITelemetryContext,
	): Promise<ISummaryTreeWithStats>;
	getGCData(fullGC?: boolean): Promise<IGarbageCollectionData>;
	updateUsedRoutes(usedRoutes: string[]): void;
	setConnectionState(connected: boolean, clientId?: string): void;
	notifyReadOnlyState?(readonly: boolean): void;
	reSubmit(type: string, content: any, localOpMetadata: unknown, squash: boolean): void;
	applyStashedOp(content: any): Promise<unknown>;
	rollback?(type: string, content: any, localOpMetadata: unknown): void;
	readonly entryPoint: IFluidHandleInternal<FluidObject>;
	request(request: IRequest): Promise<IResponse>;
	setAttachState(attachState: AttachState.Attaching | AttachState.Attached): void;
}
export type StagingModeChangedEvent =
	| { readonly inStagingMode: true }
	| { readonly inStagingMode: false; readonly commit: boolean };
export type CreateChildSummarizerNodeFn = (
	summarizeInternal: SummarizeInternalFn,
	getGCDataFn: (fullGC?: boolean) => Promise<IGarbageCollectionData>,
	getBaseGCDetailsFn?: () => Promise<IGarbageCollectionDetailsBase>,
) => ISummarizerNodeWithGC;
export interface IPendingMessagesState {
	messageCollections: IRuntimeMessageCollection[];
	pendingCount: number;
}
export interface IFluidParentContext
	extends IProvideFluidHandleContext,
		Partial<IProvideFluidDataStoreRegistry> {
	readonly options: Record<string | number, any>;
	readonly clientId: string | undefined;
	readonly connected: boolean;
	readonly isReadOnly?: () => boolean;
	readonly oldestSupportedClient: OldestSupportedClientVersion;
	readonly minVersionForCollab: OldestSupportedClientVersion;
	readonly deltaManager: IDeltaManager<ISequencedDocumentMessage, IDocumentMessage>;
	readonly storage: IRuntimeStorageService;
	readonly baseLogger: ITelemetryBaseLogger;
	readonly clientDetails: IClientDetails;
	readonly idCompressor?: IIdCompressor;
	readonly loadingGroupId?: string;
	readonly attachState: AttachState;
	readonly containerRuntime: IContainerRuntimeBase;
	readonly scope: FluidObject;
	readonly gcThrowOnTombstoneUsage: boolean;
	readonly gcTombstoneEnforcementAllowed: boolean;
	getQuorum(): IQuorumClients;
	getAudience(): IAudience;
	submitMessage(type: string, content: any, localOpMetadata: unknown): void;
	submitSignal: (type: string, content: unknown, targetClientId?: string) => void;
	makeLocallyVisible(): void;
	getAbsoluteUrl(relativeUrl: string): Promise<string | undefined>;
	getCreateChildSummarizerNodeFn(
		id: string,
		createParam: CreateChildSummarizerNodeParam,
	): CreateChildSummarizerNodeFn;
	deleteChildSummarizerNode(id: string): void;
	uploadBlob(
		blob: ArrayBufferLike,
		signal?: AbortSignal,
	): Promise<IFluidHandleInternal<ArrayBufferLike>>;
	setChannelDirty(address: string): void;
	addedGCOutboundRoute(fromPath: string, toPath: string, messageTimestampMs?: number): void;
}
export type PackagePath = readonly string[];
export interface IFluidDataStoreContext extends IFluidParentContext {
	readonly id: string;
	readonly isLocalDataStore: boolean;
	readonly packagePath: PackagePath;
	readonly baseSnapshot: ISnapshotTree | undefined;
	readonly createProps?: any;
	getBaseGCDetails(): Promise<IGarbageCollectionDetailsBase>;
	createChildDataStore?<T extends IFluidDataStoreFactory>(
		childFactory: T,
	): ReturnType<Exclude<T["createDataStore"], undefined>>;
}
export interface FluidDataStoreContextInternal
	extends IFluidDataStoreContext,
		ContainerExtensionProvider {}
export interface IFluidDataStoreContextDetached extends IFluidDataStoreContext {
	attachRuntime(
		factory: IProvideFluidDataStoreFactory,
		dataStoreRuntime: IFluidDataStoreChannel,
	): Promise<IDataStore>;
}
```

### dataStoreFactory: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreFactory.ts:1-82`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export const IFluidDataStoreFactory: keyof IProvideFluidDataStoreFactory =
	"IFluidDataStoreFactory";
export interface IProvideFluidDataStoreFactory {
	readonly IFluidDataStoreFactory: IFluidDataStoreFactory;
}
export interface IFluidDataStoreFactory extends IProvideFluidDataStoreFactory {
	type: string;
	instantiateDataStore(
		context: IFluidDataStoreContext,
		existing: boolean,
	): Promise<IFluidDataStoreChannel>;
	createDataStore?(context: IFluidDataStoreContext): {
		readonly runtime: IFluidDataStoreChannel;
	};
}
```

### dataStoreRegistry: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreRegistry.ts:1-80`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export type FluidDataStoreRegistryEntry = Readonly<
	Partial<IProvideFluidDataStoreRegistry & IProvideFluidDataStoreFactory>
>;
export type NamedFluidDataStoreRegistryEntry = [string, Promise<FluidDataStoreRegistryEntry>];
export type NamedFluidDataStoreRegistryEntry2 = [
	string,
	Promise<FluidDataStoreRegistryEntry> | FluidDataStoreRegistryEntry,
];
export type NamedFluidDataStoreRegistryEntries = Iterable<NamedFluidDataStoreRegistryEntry2>;
export const IFluidDataStoreRegistry: keyof IProvideFluidDataStoreRegistry =
	"IFluidDataStoreRegistry";
export interface IProvideFluidDataStoreRegistry {
	readonly IFluidDataStoreRegistry: IFluidDataStoreRegistry;
}
export interface IFluidDataStoreRegistry extends IProvideFluidDataStoreRegistry {
	get(name: string): Promise<FluidDataStoreRegistryEntry | undefined>;
	getSync?(name: string): FluidDataStoreRegistryEntry | undefined;
}
```

### protocol: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/protocol.ts:1-187`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export interface IEnvelope<TContents = any> {
	address: string;
	contents: TContents;
}
export interface IInboundSignalMessage<TMessage extends TypedMessage = TypedMessage>
	extends ISignalMessage<TMessage> {
	readonly type: TMessage["type"];
}
export interface IAttachMessage {
	id: string;
	type: string;
	snapshot: ITree;
}
export type InboundAttachMessage = Omit<IAttachMessage, "snapshot"> & {
	snapshot: IAttachMessage["snapshot"] | null;
};
export type ISequencedMessageEnvelope = Omit<
	ISequencedDocumentMessage,
	"contents" | "clientSequenceNumber"
>;
export interface IRuntimeMessagesContent {
	readonly contents: unknown;
	readonly localOpMetadata: unknown;
	readonly clientSequenceNumber: number;
}
export interface IRuntimeMessageCollection {
	readonly envelope: ISequencedMessageEnvelope;
	readonly local: boolean;
	readonly messagesContent: readonly IRuntimeMessagesContent[];
}
export interface FluidDataStoreMessage {
	type: string;
	content: unknown;
}
export interface IRuntimeStorageService {
	readBlob(id: string): Promise<ArrayBufferLike>;
}
```

### summary: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/summary.ts:1-399`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export interface ISummaryStats {
	treeNodeCount: number;
	blobNodeCount: number;
	handleNodeCount: number;
	totalBlobSize: number;
	unreferencedBlobSize: number;
}
export interface ISummaryTreeWithStats {
	stats: ISummaryStats;
	summary: ISummaryTree;
}
export interface ISummarizeResult {
	stats: ISummaryStats;
	summary: SummaryTree;
}
export interface ISummarizeInternalResult extends ISummarizeResult {
	id: string;
	pathPartsForChildren?: string[];
}
export interface IExperimentalIncrementalSummaryContext {
	readonly summarySequenceNumber: number;
	readonly latestSummarySequenceNumber: number;
	readonly summaryPath: string;
}
export type SummarizeInternalFn = (
	fullTree: boolean,
	trackState: boolean,
	telemetryContext?: ITelemetryContext,
	incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
) => Promise<ISummarizeInternalResult>;
export interface ISummarizerNodeConfig {
	readonly canReuseHandle?: boolean;
}
export interface ISummarizerNodeConfigWithGC extends ISummarizerNodeConfig {
	readonly gcDisabled?: boolean;
}
export enum CreateSummarizerNodeSource {
	FromSummary,
	FromAttach,
	Local,
}
export type CreateChildSummarizerNodeParam =
	| {
			type: CreateSummarizerNodeSource.FromSummary;
	  }
	| {
			type: CreateSummarizerNodeSource.FromAttach;
			sequenceNumber: number;
			snapshot: ITree;
	  }
	| {
			type: CreateSummarizerNodeSource.Local;
	  };
export interface ISummarizerNode {
	readonly referenceSequenceNumber: number;
	invalidate(sequenceNumber: number): void;
	summarize(
		fullTree: boolean,
		trackState?: boolean,
		telemetryContext?: ITelemetryContext,
	): Promise<ISummarizeResult>;
	updateBaseSummaryState(snapshot: ISnapshotTree): void;
	recordChange(op: ISequencedDocumentMessage): void;
	createChild(
		summarizeInternalFn: SummarizeInternalFn,
		id: string,
		createParam: CreateChildSummarizerNodeParam,
		config?: ISummarizerNodeConfig,
	): ISummarizerNode;
	getChild(id: string): ISummarizerNode | undefined;
	isSummaryInProgress?(): boolean;
}
export interface ISummarizerNodeWithGC extends ISummarizerNode {
	createChild(
		summarizeInternalFn: SummarizeInternalFn,
		id: string,
		createParam: CreateChildSummarizerNodeParam,
		config?: ISummarizerNodeConfigWithGC,
		getGCDataFn?: (fullGC?: boolean) => Promise<IGarbageCollectionData>,
		getBaseGCDetailsFn?: () => Promise<IGarbageCollectionDetailsBase>,
	): ISummarizerNodeWithGC;
	deleteChild(id: string): void;
	getChild(id: string): ISummarizerNodeWithGC | undefined;
	getGCData(fullGC?: boolean): Promise<IGarbageCollectionData>;
	isReferenced(): boolean;
	updateUsedRoutes(usedRoutes: string[]): void;
}
export const channelsTreeName = ".channels";
export interface ITelemetryContextExt {
	set(prefix: string, property: string, value: TelemetryEventPropertyTypeExt): void;
	setMultiple(
		prefix: string,
		property: string,
		values: Record<string, TelemetryEventPropertyTypeExt>,
	): void;
}
export interface ITelemetryContext {
	set(prefix: string, property: string, value: TelemetryBaseEventPropertyType): void;
	setMultiple(
		prefix: string,
		property: string,
		values: Record<string, TelemetryBaseEventPropertyType>,
	): void;
}
export const blobCountPropertyName = "BlobCount";
export const totalBlobSizePropertyName = "TotalBlobSize";
export const currentSummarizeStepPrefix = "";
export const currentSummarizeStepPropertyName = "CurrentSummarizeStep";
```

### garbageCollectionDefinitions: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/garbageCollectionDefinitions.ts:1-62`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export const gcTreeKey = "gc";
export const gcBlobPrefix = "__gc";
export const gcTombstoneBlobKey = "__tombstones";
export const gcDeletedBlobKey = "__deletedNodes";
export const gcDataBlobKey = ".gcdata";
export interface IGarbageCollectionData {
	gcNodes: { [id: string]: string[] };
}
export interface IGarbageCollectionDetailsBase {
	usedRoutes?: string[];
	gcData?: IGarbageCollectionData;
}
```

### attribution: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/attribution.ts:1-78`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export interface OpAttributionKey {
	type: "op";
	seq: number;
}
export interface DetachedAttributionKey {
	type: "detached";
	id: 0;
}
export interface LocalAttributionKey {
	type: "local";
}
export type AttributionKey = OpAttributionKey | DetachedAttributionKey | LocalAttributionKey;
export interface AttributionInfo {
	user: IUser;
	timestamp: number;
}
```

### containerExtensionProvider: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/containerExtensionProvider.ts:1-105`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export interface ExtensionCompatibilityDetails {
	readonly generation: number;
	readonly version: string;
	readonly capabilities: ReadonlySet<string>;
}
export interface UnknownExtensionInstantiation {
	compatibility: ExtensionCompatibilityDetails;
	interface: unknown;
	extension: unknown;
}
export interface ContainerExtensionExpectations {
	readonly hostRequirements: ILayerCompatSupportRequirements;
	readonly instanceExpectations: ExtensionCompatibilityDetails;
	resolvePriorInstantiation(
		priorInstantiation: UnknownExtensionInstantiation,
	): Readonly<UnknownExtensionInstantiation>;
}
export type ContainerExtensionId = `${string}:${string}`;
export interface ContainerExtensionProvider {
	getExtension<TInterface, TUseContext extends unknown[] = []>(
		id: ContainerExtensionId,
		expectations: ContainerExtensionExpectations,
		...context: TUseContext
	): TInterface;
}
```

### compatibilityDefinitions: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/compatibilityDefinitions.ts:1-69`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export type OldestSupportedClientVersion = `3.${bigint}.0` | `2.${bigint}.${bigint}`;
export type MinimumVersionForCollab = OldestSupportedClientVersion;
```

### runtimeLayerCompatFeatureNames: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/runtimeLayerCompatFeatureNames.ts:1-19`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export const encodeHandlesInContainerRuntime = "encodeHandlesInContainerRuntime";
export const notifiesReadOnlyState = "notifiesReadOnlyState";
```

### versionMarks: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/versionMarks.ts:1-121`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export type ResolveResult =
	| {
			readonly kind: "resolved";
			readonly sequenceNumber: number;
			readonly timestamp?: number;
	  }
	| {
			readonly kind: "pending";
			readonly reason?: string;
	  }
	| {
			readonly kind: "unresolvable";
			readonly reason?: string;
	  };
export type VersionMarkCapture =
	| {
			readonly kind: "pending";
			readonly batchId: string;
			readonly sequenceNumberLowerBound: number;
	  }
	| {
			readonly kind: "resolved";
			readonly sequenceNumber: number;
			readonly timestamp?: number;
	  };
export interface IVersionMarkResolver {
	sealAndCaptureVersionMark(): VersionMarkCapture;
	resolve(batchId: string, sequenceNumberLowerBound: number): Promise<ResolveResult>;
	onBatchSequenced(
		listener: (batchId: string, sequenceNumber: number, timestamp?: number) => void,
	): () => void;
}
```

### stagingMode: literal contract

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/stagingMode.ts:1-100`. The listing specifies exact members, optionality, defaults, guards and execution order; comments and imports are omitted. Types owned by another package retain their upstream names.

```typescript
export interface CommitStagedChangesOptionsInternal {
	squash?: boolean;
}
export interface StageControlsInternal extends StageControls {
	readonly commitChanges: (options?: Partial<CommitStagedChangesOptionsInternal>) => void;
}
export interface IContainerRuntimeBaseInternal extends IContainerRuntimeBase {
	enterStagingMode(): StageControlsInternal;
	getDataStorePackagePath(nodePath: string): Promise<PackagePath | undefined>;
}
export interface StageControlsAlpha extends StageControls {}
export interface ContainerRuntimeBaseAlpha extends IContainerRuntimeBase {}
export function asLegacyAlpha(base: IContainerRuntimeBase): ContainerRuntimeBaseAlpha {
	return base as ContainerRuntimeBaseAlpha;
}
```

## 3. Wire and persisted formats

- Routing envelope is `{address:string,contents:T}`. Example channel payload: `{"address":"counter","contents":{"incrementAmount":1}}`. The interface fixes names, not insertion order; datastore writer emits address then contents. `FluidDataStoreMessage` is a distinct `{type:string,content:unknown}` (singular **content**). It is not the channel envelope. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/protocol.ts:1-187` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1339-1364`
- Outgoing attach is `{id:string,type:string,snapshot:ITree}`; incoming legacy attach admits `snapshot:null`. The concrete channel writer emits id,snapshot,type, not interface declaration order. A handle-free empty DDS with type T and snapshot version1 produces `{"id":"c1","snapshot":{"entries":[{"path":".attributes","mode":"100644","type":"Blob","value":{"contents":"{\"type\":\"T\",\"snapshotFormatVersion\":\"1\"}","encoding":"utf-8"}},{"path":".gcdata","mode":"100644","type":"Blob","value":{"contents":"{\"gcNodes\":{\"/\":[]}}","encoding":"utf-8"}}]},"type":"T"}`. Snapshot entries use the driver's ITree, not an ISummaryTree. No new wire version is introduced here. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/protocol.ts:1-187` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1298-1337`
- `IRuntimeMessageCollection` is **in-memory**, with `envelope`, `local`, `messagesContent`. The envelope omits contents and clientSequenceNumber. Each array member has `contents:unknown`, `localOpMetadata:unknown`, `clientSequenceNumber:number`; metadata is not sent to the server and is undefined for remote messages, possibly undefined for local messages too. A grouped batch is contiguous, same client/reference sequence, not interleaved, and actually submitted grouped; a bunch is a contiguous same-DDS subsequence. A,B,A is three bunches, not two. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/protocol.ts:1-187`
- GC data is `{"gcNodes":{"/":["/store/channel"]}}`, node keys to ordered route arrays. Initial details are `{usedRoutes?:string[],gcData?:IGarbageCollectionData}`; neither property is implicitly null. Constants: `gcTreeKey="gc"`, `gcBlobPrefix="__gc"`, `gcTombstoneBlobKey="__tombstones"`, `gcDeletedBlobKey="__deletedNodes"`, `gcDataBlobKey=".gcdata"`; child isolation key `channelsTreeName=".channels"`. These declarations do not define the container GC blob version/schema beyond the GC-data object. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/garbageCollectionDefinitions.ts:1-62` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/summary.ts:1-399`
- Summary stats fields are `treeNodeCount`, `blobNodeCount`, `handleNodeCount`, `totalBlobSize`, `unreferencedBlobSize`, all numbers. `ISummaryTreeWithStats` requires a tree; `ISummarizeResult` allows a tree or summary handle. Internal result additionally requires `id` and optional `pathPartsForChildren:string[]`; these are bookkeeping, not extra summary blobs. Incremental context requires `summarySequenceNumber`, `latestSummarySequenceNumber`, `summaryPath`. Example wrapper from a builder is `{"summary":{"type":1,"tree":{}},"stats":{"treeNodeCount":1,"blobNodeCount":0,"handleNodeCount":0,"totalBlobSize":0,"unreferencedBlobSize":0}}`; wrapper field order comes from the writer, not interface declaration order. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/summary.ts:1-399` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:192-288`
- Attribution values: op `{type:"op",seq:number}` (not `key` despite the source comment), detached `{type:"detached",id:0}`, local `{type:"local"}`. AttributionInfo is `{user:IUser,timestamp:number}`. These are value contracts; the package defines no JSON emitter or compressed attribution persistence. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/attribution.ts:1-78`
- Staging event union: `{inStagingMode:true}` or `{inStagingMode:false,commit:boolean}`; no commit on entry. Version capture: pending `{kind:"pending",batchId:string,sequenceNumberLowerBound:number}`, resolved `{kind:"resolved",sequenceNumber:number,timestamp?:number}`. Resolution adds `{kind:"unresolvable",reason?:string}` and pending `reason?:string`. Reasons are transient diagnostics, never persisted or branch discriminators; runtime defines no app-stored locator record. Example valid capture value `{"kind":"pending","batchId":"client_1","sequenceNumberLowerBound":12}` is illustrative of the declared value, not a package JSON writer. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/versionMarks.ts:1-121`

## 4. Behavior

### Context, visibility and factory lifecycle

`FlushMode.Immediate=0`, `TurnBased=1`; immediate submits directly, turn-based buffers until end of the turn or explicit flush. Visibility strings are exactly `NotVisible`, `LocallyVisible`, `GloballyVisible`. Binding into a detached graph makes an object locally visible; graph attachment to a globally visible container makes it globally visible. Visibility is not socket connection, and locality is not visibility: `isLocalDataStore` remains fixed for the instance even after attachment; rehydrated detached stores count as local. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833`

Creation by `createDataStore` returns an unbound store; retaining it only in ordinary process memory does not persist it. Putting its handle (or a descendant handle) in a graph that becomes attached attaches it. `createDetachedDataStore` is not initialization completion: call `attachRuntime(factory,channel)`. Registry package path is an ordered string array selecting successive registry entries; aliases return exactly Success, Conflict or AlreadyAliased. Conflict means another store owns the name and the losing store cannot be retargeted to a different alias; obtain the winner via `getAliasedDataStoreEntryPoint`. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833`

Asynchronous factory `instantiateDataStore(context,existing)` handles both creation and load; synchronous optional `createDataStore(context)` returns `{runtime}`. Synchronous child creation requires parent factory also be a registry, that registry return the **same factory instance** synchronously via getSync, and child implement createDataStore. Later loads still use asynchronous instantiateDataStore. Registry get returns a promise of optional entry; optional getSync returns optional entry directly. An entry may expose factory, registry, or both. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreFactory.ts:1-82` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreRegistry.ts:1-80`

### Runtime control and replay boundary

Context submits `(type,content,localOpMetadata)` separately. Channel receives synchronous processMessages/processSignal/setConnectionState; asynchronous applyStashedOp returns locally reconstructed metadata; optional rollback reverses a local message. `reSubmit(type,content,metadata,squash)` can result in no replacement, one or many. Squash removes unnecessary intermediate edits, not necessarily coalescing all pending edits into one op. Channel attach summary and attach GC are synchronous; ordinary summarize and getGCData are async. `notifyReadOnlyState` is optional and advertised with `notifiesReadOnlyState`; context `isReadOnly` is itself optional at the public interface. `encodeHandlesInContainerRuntime` means datastore must bind handles but not encode them again. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/runtimeLayerCompatFeatureNames.ts:1-19` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/stagingMode.ts:1-100`

Staging retains new ops locally until commit; discard can fail where DDS rollback is unsupported. `readonlyInStagingMode` is a best-effort appearance policy, not mutation enforcement; it prevents consensus-dependent UX from waiting on acknowledgments that cannot arrive yet. `hasStagedChanges` is separate from ordinary dirty/unacknowledged work. Dispose in staging silently drops staged edits and emits no staging-mode transition. Event listener tuples are literal in section 2: batchBegin(first envelope), batchEnd(error,last envelope), op(message,runtimeMessage?), signal(message,local), dispose(), stagingModeChanged(info), hasStagedChangesChanged(boolean). Declarations do not specify cross-event ordering beyond these semantics; emitting order belongs to implementing runtime. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833`

### Summarizer and version marks

Summarizer child source values are FromSummary=0, FromAttach=1, Local=2. FromAttach additionally requires sequenceNumber and ITree snapshot. FromSummary requires previously seen summary state; Local has no supported ordinary summarize until its implementation's attach transition. Config canReuseHandle defaults true by contract; gcDisabled propagates to children. invalidate/recordChange mark sequence changes; updateUsedRoutes reports reachability and detects used-route changes. getGCData(fullGC) bypasses optimizations when fullGC=true. The summary handle paths include `.channels`; updateBaseSummaryState is an old compatibility API, not a new path layout. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/summary.ts:1-399`

sealAndCaptureVersionMark seals the outbound batch first, then atomically captures the latest unacked batch or current sequenced position. Do not call while manually accumulating an orderSequentially batch: forbidden flush throws and closes the container. Resolve searches starting at an **inclusive** sequence-number lower bound; empty reads, gaps and missing historical batches remain pending, not terminal. onBatchSequenced supplies the batch's final sequence number and final op server timestamp; returned function unsubscribes. Timestamps can be absent if no processed/summary op supplies one. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/versionMarks.ts:1-121`

Extension IDs contain a colon and must not contain `/`; compatibility holds generation:number, version:string, capabilities:ReadonlySet<string>. Expectations contain hostRequirements, instanceExpectations and a resolvePriorInstantiation callback; instantiation holds compatibility, interface, extension. These sets/objects are in-process, not JSON. `OldestSupportedClientVersion` permits type strings `3.${bigint}.0` or `2.${bigint}.${bigint}`; runtime validation is stricter than that TypeScript syntax. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/containerExtensionProvider.ts:1-105` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/compatibilityDefinitions.ts:1-69`

## 5. Invariants and asserts

None execute in this declaration package. The lifecycle and capability requirements above are caller/implementer obligations, not schema validation supplied by an interface. `asLegacyAlpha` is only a cast and returns the exact same object. No assert short codes occur in these files. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/stagingMode.ts:1-100` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833`

## 6. JS-semantics hazards

Do not encode enums by Swift case name: the source mixes numeric and string enums. Distinguish absent optional methods from methods returning undefined, and distinguish null legacy attach snapshots from omitted members. `unknown` metadata must retain identity and is not a JSON round trip. Promise resolution is not synchronous callback execution; synchronous channel hooks must remain on the container executor, while storage/load awaits occur at the I/O boundary. A declaration's member order is not a producer's JSON insertion order. Preserve the two compatibility property names oldestSupportedClient and minVersionForCollab at the cross-version boundary. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/protocol.ts:1-187` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/dataStoreContext.ts:1-833` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/summary.ts:1-399`

## 7. Test assets to reuse

The package's compile-time tests pin allowable compatibility version literals and export compatibility; they are type-surface evidence, not runtime wire fixtures. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/test/types/oldestSupportedClientVersion.ts:1-30` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/test/types/validateRuntimeDefinitionsPrevious.generated.ts:1-954`

Runtime scenarios exercising these declarations: datastore routing/attach/GC tests and runtime-utils summary conversion/compatibility tests. Port their data and expectations, not only interface compilation. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/dataStoreRuntime.spec.ts:1` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/summaryUtils.spec.ts:1` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/compatibilityBase.spec.ts:1`

## 8. Open questions

None for this package's declarations. It intentionally provides no app version-mark persistence schema or container GC-state serializer.
