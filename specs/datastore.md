# datastore — native Swift port contract (3.11.0)

## 1. Role

Hosts DDS channels within one datastore, multiplexes channel ops, controls lazy realization/attachment, storage, handles and GC. It delegates container-level sequencing and persisted datastore wrapping to IFluidDataStoreContext. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:210-260`

## 2. Surface used by other packages

`FluidDataStoreRuntime`, `DataStoreMessageType`, shared-object registry and runtime summary mixin are the external entry points. ChannelContext/local/remote, delta connection and storage form the internal DDS service boundary. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/index.ts:6-19`



## 3. Wire and persisted formats

### Op and attach shapes

Runtime type strings: `"op"` and `"attach"`. DDS submission constructs `{address:string,contents:unknown}` in that order, then sends `(type="op", envelope, localOpMetadata)` to its parent context. Example: address `c1`, DDS body `{"n":1}` yields `{"address":"c1","contents":{"n":1}}`. Metadata is not included on wire. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:136-141` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1339-1357`

Channel attach construction order is **`id`, `snapshot`, `type`**, despite the type interface declaring type before snapshot. `id:string` is channel ID; `snapshot:ITree` is full current DDS summary converted to entries, including `.attributes` and `.gcdata`; `type:string` is channel.attributes.type. Minimal concrete example for a DDS with empty summary, attributes inserted `type`, `snapshotFormatVersion`, and no handles: `{"id":"c1","snapshot":{"entries":[{"path":".attributes","mode":"100644","type":"Blob","value":{"contents":"{\"type\":\"T\",\"snapshotFormatVersion\":\"1\"}","encoding":"utf-8"}},{"path":".gcdata","mode":"100644","type":"Blob","value":{"contents":"{\"gcNodes\":{\"/\":[]}}","encoding":"utf-8"}}]},"type":"T"}`. The snapshot object also owns undefined `unreferenced` and `groupId` in memory, omitted by JSON.stringify. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1314-1336` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:435-484`

### Summary layout and ownership

DDS summary tree contains its own blobs plus `.attributes` appended by channel wrapper. Runtime returns a tree keyed directly by channel IDs, **not** a `.channels` node. The parent container-runtime datastore context wraps this tree in `.channels` and writes datastore attributes under **`.component`**, not `.attributes`. Thus modern storage is `/.channels/<store>/.component`, `/.channels/<store>/.channels/<dds>/.attributes` and DDS blobs under that DDS node. Confusing these two attributes blobs breaks factory resolution. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:111-148` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1099-1113` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/summary/summaryFormat.ts:242-281`

Datastore `.component` content emission order is `pkg` (a **JSON string containing a JSON array**, e.g. `"[\"example\"]"`), `summaryFormatVersion:2`, `isRootDataStore:boolean`. Exact blob example: `{"pkg":"[\"example\"]","summaryFormatVersion":2,"isRootDataStore":false}`. Version 0 has no version markers and pkg plain string; version 1 has snapshotFormatVersion `"0.1"` and array-in-string pkg; version 2 uses summaryFormatVersion 2 and optional `disableIsolatedChannels:true`. Isolation is truthy summaryFormatVersion and !disableIsolatedChannels. Each datastore decides isolation independently. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/dataStoreContext.ts:109-125` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/summary/summaryFormat.ts:39-121`

Channel `.attributes` is JSON of `{type:string,snapshotFormatVersion:string,packageVersion?:string}` preserving producer object order; old attach snapshots may omit it, in which case attach type selects factory and factory attributes become defaults. Existing attributes' type takes precedence over attach type; mismatched snapshot version emits telemetry but does not reject load. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/storage.ts:10-26` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:150-213`

GC shape is `{gcNodes:{[nodeId:string]:string[]}}`; channel attach `.gcdata` literal example `{"gcNodes":{"/":[]}}`. Datastore prefixes child node IDs, adds a parent absolute-path back edge to every child, then adds `/` with edges to all contexts. Signal is not a sequenced op: submit delegates `(type,content,targetClientId?)`; receive emits `signal(message,local)` unchanged. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1069-1092` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1116-1141` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1047-1049` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1280-1283`


## 4. Behavior

### Construction and channel realization

Constructor binds context services, builds handle/routing contexts, evaluates layer feature compatibility and scans base snapshot channels. Existing remote snapshots become RemoteChannelContext; detached snapshot rehydration becomes RehydratedLocalChannelContext; newly created DDS gets LocalChannelContext. Context registration is not DDS realization. Per-channel lazy promise is shared so concurrent consumers cannot instantiate twice. Remote realization loads attributes/factory then DDS, replays queued collections in order, commits channel and clears queue, sets loaded=true, refreshes current connection state, returns channel. Failures wrap as `remoteChannelContextFailedToLoadChannel` with RealizeError telemetry. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:399-562` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:68-189`

Local context only propagates connection changes once globally visible and loaded. Pending remote content is shallow-copied (including its messagesContent array) while unrealized. makeVisible connects an already realized channel to services, processes pending messages, then establishes visibility according to the exact ordered listing. Rehydrated-local loading maintains the same lazy boundary rather than eagerly instantiating all snapshot channels. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:43-402`

### Routing, acknowledgments and replay

1. Receive verifies runtime not closed. For own collection decrement pendingOpCount by number of contents **before** dispatch. Switch envelope.type: op routes, attach processes attachments, unknown type is ignored for dispatch. Wrap dispatch errors as `fluidDataStoreRuntimeFailedToProcessMessage`. After successful dispatch emit runtime `op` once per original content, overriding envelope contents/clientSequenceNumber. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1013-1045`
2. Route contiguous same-address runs only: A,B,A produces three bunches, never two regrouped collections. Unwrap one envelope layer, preserve each local metadata/client sequence and common envelope/local flag. Missing context asserts 0xa6b. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:922-968`
3. Each attach processes GC routes **before** testing local flag; fromPath is `/store/channel` for root node `/`, otherwise append node suffix. Own attach must delete pendingAttach; remote must not already exist and gets a FromAttach summarizer child context before registration. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:971-1010`
4. ChannelDeltaConnection expands symbol-marked stashed metadata into zero, one or multiple concrete content/metadata pairs, retaining original clientSequenceNumber for every expansion. During applyStashedOp set a private marked array only if attached+visible; submissions append to it rather than call submitFn. Return that array then clear capture in finally. Resubmit and rollback expand this array too. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:17-154`
5. Runtime resubmit decrements pending count before channel hook or direct attach retransmission; each new submit increments count **after** parent submit returns. Rollback accepts op only, decrements count, uses localOpActivity guard and clears in finally. Stashed op increments count before applying because an old acknowledgment may still arrive; the activity guard prevents ordinary submissions from escaping replay. Exact attach/stash cases are retained below. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1351-1512`

### Visibility, summaries, GC and events

Binding removes an unbound ID and either immediately makes a DDS visible in attached datastore or queues it for datastore attachment. Graph attachment follows bound handle graphs before sharing. Making a channel locally visible: skip attached handle; attach its graph; require datastore attached and globally visible; generate full summary, append .attributes then .gcdata, convert to ITree; add pendingAttach; submit attach; call context.makeVisible. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:774-849` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1298-1337`

Datastore attaching: attachGraph first, set attachState=Attaching, require locally visible, mark globally visible, make queued channels visible in Map order, clear queue, resolve deferredAttached **before** emit `attaching`. Attached: require globally visible, set state, emit `attached`. Promise callbacks run after the synchronous event stack. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1581-1627`

Summary traverses contexts sequentially in insertion order, asserts each fully attached, awaits each summary, adds child and stats. Attach summary traverses local bound contexts; loaded ones summarize synchronously, unrealized ones reuse detached base snapshots. GC performs same sequential visit, prefixes child keys, adds parent back edges, adds root. updateUsedRoutes first splits routes by child and validates each known context, then updates every context using [] for unused. Remote contexts currently force usedRoutes=[""] so DDS-level GC does not collect them. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1099-1269` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:293-303`


### Attach traversal, connection and disposal edge ordering

Attach traversal is a fixed-point loop, not a snapshot of currently bound contexts: require LocallyVisible (0xc2c), maintain visited IDs, repeatedly enumerate the live contexts Map; require each context be LocalChannelContextBase, skip visited or unbound IDs, invoke visitor **before** marking visited, repeat until an entire pass adds no new visited IDs. A visitor can bind another DDS, including one earlier in Map order; that newly bound DDS must join the same attach summary. Loaded local summaries use fullTree=true/trackState=false; unloaded rehydrated local summaries reuse base snapshots, whereas their attach-GC contribution is skipped before runtime root/back-edge aggregation. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1144-1271` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:152-180`

Connection propagation visits every context synchronously before runtime connected/disconnected notification. notifyReadOnlyState verifies not closed; only changed value is stored then emits readonly(value). dispose is idempotent: return if disposed; set disposed=true; emit dispose; removeAllListeners. It does not eagerly dispose every DDS/context or clear all maps. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:581-589` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:845-872`

Stashed attach reconstruction builds snapshot and flat blob map, creates rehydrated local context, awaits channel load **before** registering context. Detached adds queue entry; attached calls makeVisible then adds pendingAttach. Stashed channel op awaits getChannel then applies contents. Both set localOpActivity before incrementing pending count and clear activity in finally; the count is not rolled back if application throws. A resubmit decrements pending count before selecting channel/attach branch, and each resulting submission increments only after parent submitMessage succeeds. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1351-1512`

### dataStoreLayerCompatState: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreLayerCompatState.ts:1-89`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export const dataStoreCoreCompatDetails = {
	pkgVersion,
	generation,
} as const;
export const dataStoreCompatDetailsForRuntime: ILayerCompatDetails = {
	...dataStoreCoreCompatDetails,
	supportedFeatures: new Set<string>(),
};
export const runtimeSupportRequirementsForDataStore: ILayerCompatSupportRequirements = {
	minSupportedGeneration: Math.max(
		0,
		dataStoreCoreCompatDetails.generation -
			LayerCompatibilityPolicyWindowMonths.NewDataStoreOldRuntime,
	),
	requiredFeatures: [],
};
export function validateRuntimeCompatibility(
	maybeRuntimeCompatDetails: ILayerCompatDetails | undefined,
	disposeFn: () => void,
	mc: MonitoringContext,
): void {
	validateLayerCompatibility(
		 {
			layer: "dataStore",
			packageInfo: dataStoreCoreCompatDetails,
			compatSupportRequirements: runtimeSupportRequirementsForDataStore,
		},
		 {
			layer: "runtime",
			compatDetails: maybeRuntimeCompatDetails,
		},
		{ disposeFn, mc },
	);
}
```

### fluidHandle: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/fluidHandle.ts:1-57`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class FluidObjectHandle<
	T extends FluidObject = FluidObject,
> extends FluidHandleBase<T> {
	public readonly absolutePath: string;
	public get isAttached(): boolean {
		return this.routeContext.isAttached;
	}
	constructor(
		protected readonly value: T | Promise<T>,
		public readonly path: string,
		public readonly routeContext: IFluidHandleContext,
	) {
		super();
		this.absolutePath = generateHandleContextPath(path, this.routeContext);
	}
	public async get(): Promise<any> {
		return this.value;
	}
	public attachGraph(): void {
		this.routeContext.attachGraph();
	}
}
```

### channelStorageService: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelStorageService.ts:1-85`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class ChannelStorageService implements IChannelStorageService {
	private static flattenTree(
		base: string,
		tree: ISnapshotTree,
		results: { [path: string]: string },
	): void {
		for (const [path, subtree] of Object.entries(tree.trees)) {
			ChannelStorageService.flattenTree(`${base}${path}/`, subtree, results);
		}
		for (const [blobName, blobId] of Object.entries(tree.blobs)) {
			results[`${base}${blobName}`] = blobId;
		}
	}
	private readonly flattenedTree: { [path: string]: string };
	constructor(
		private readonly tree: ISnapshotTree | undefined,
		private readonly storage: Pick<IRuntimeStorageService, "readBlob">,
		private readonly logger: TelemetryLoggerExt,
		private readonly extraBlobs?: Map<string, ArrayBufferLike>,
	) {
		this.flattenedTree = {};
		if (tree !== undefined) {
			ChannelStorageService.flattenTree("", tree, this.flattenedTree);
		}
	}
	public async contains(path: string): Promise<boolean> {
		return this.flattenedTree[path] !== undefined;
	}
	public async readBlob(path: string): Promise<ArrayBufferLike> {
		const id = await this.getIdForPath(path);
		assert(id !== undefined, 0x9d7 );
		const blob = this.extraBlobs === undefined ? undefined : this.extraBlobs.get(id);
		if (blob !== undefined) {
			return blob;
		}
		const blobP = this.storage.readBlob(id);
		blobP.catch((error) =>
			this.logger.sendErrorEvent({ eventName: "ChannelStorageBlobError" }, error),
		);
		return blobP;
	}
	public async list(path: string): Promise<string[]> {
		let tree = this.tree;
		const pathParts = getNormalizedObjectStoragePathParts(path);
		while (tree !== undefined && pathParts.length > 0) {
			const part = pathParts.shift()!;
			tree = tree.trees[part];
		}
		if (tree === undefined || pathParts.length > 0) {
			throw new Error("path does not exist");
		}
		return Object.keys(tree?.blobs ?? {});
	}
	public getSnapshotTree(): ISnapshotTree | undefined {
		return this.tree;
	}
	private async getIdForPath(path: string): Promise<string | undefined> {
		return this.flattenedTree[path];
	}
}
```

### channelDeltaConnection: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:1-154`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
const stashedOpMetadataMark = Symbol();
type StashedOpMetadata = { contents: unknown; metadata: unknown }[] &
	Record<typeof stashedOpMetadataMark, typeof stashedOpMetadataMark>;
function createStashedOpMetadata(): StashedOpMetadata {
	const arr = [];
	Object.defineProperty(arr, stashedOpMetadataMark, {
		value: stashedOpMetadataMark,
		writable: false,
		enumerable: true,
	});
	return arr as unknown as StashedOpMetadata;
}
function isStashedOpMetadata(md: unknown): md is StashedOpMetadata {
	return (
		Array.isArray(md) &&
		stashedOpMetadataMark in md &&
		md[stashedOpMetadataMark] === stashedOpMetadataMark
	);
}
function processWithStashedOpMetadataHandling(
	content: unknown,
	localOpMetaData: unknown,
	func: (contents: unknown, metadata: unknown) => void,
): void {
	if (isStashedOpMetadata(localOpMetaData)) {
		for (const { contents, metadata } of localOpMetaData) func(contents, metadata);
	} else {
		func(content, localOpMetaData);
	}
}
function getContentsWithStashedOpHandling(
	messagesContent: readonly IRuntimeMessagesContent[],
): IRuntimeMessagesContent[] {
	const newMessageContents: IRuntimeMessagesContent[] = [];
	for (const messageContent of messagesContent) {
		if (isStashedOpMetadata(messageContent.localOpMetadata)) {
			for (const { contents, metadata } of messageContent.localOpMetadata) {
				newMessageContents.push({
					contents,
					localOpMetadata: metadata,
					clientSequenceNumber: messageContent.clientSequenceNumber,
				});
			}
		} else {
			newMessageContents.push(messageContent);
		}
	}
	return newMessageContents;
}
export class ChannelDeltaConnection implements IDeltaConnection {
	private _handler: IDeltaHandler | undefined;
	private stashedOpMd: StashedOpMetadata | undefined;
	private get handler(): IDeltaHandler {
		assert(!!this._handler, 0x177 );
		return this._handler;
	}
	public get connected(): boolean {
		return this._connected;
	}
	constructor(
		private _connected: boolean,
		private readonly submitFn: (content: unknown, localOpMetadata: unknown) => void,
		public readonly dirty: () => void,
		private readonly isAttachedAndVisible: () => boolean,
	) {}
	public attach(handler: IDeltaHandler): void {
		assert(this._handler === undefined, 0x178 );
		this._handler = handler;
	}
	public setConnectionState(connected: boolean): void {
		this._connected = connected;
		this.handler.setConnectionState(connected);
	}
	public processMessages(messageCollection: IRuntimeMessageCollection): void {
		try {
			const newMessagesContent = getContentsWithStashedOpHandling(
				messageCollection.messagesContent,
			);
			this.handler.processMessages({
				...messageCollection,
				messagesContent: newMessagesContent,
			});
		} catch (error) {
			throw DataProcessingError.wrapIfUnrecognized(
				error,
				"channelDeltaConnectionFailedToProcessMessages",
				messageCollection.envelope,
			);
		}
	}
	public reSubmit(content: unknown, localOpMetadata: unknown, squash: boolean): void {
		processWithStashedOpMetadataHandling(content, localOpMetadata, (contents, metadata) =>
			this.handler.reSubmit(contents, metadata, squash),
		);
	}
	public rollback(content: unknown, localOpMetadata: unknown): void {
		if (this.handler.rollback === undefined) {
			throw new Error("Handler doesn't support rollback");
		}
		processWithStashedOpMetadataHandling(
			content,
			localOpMetadata,
			this.handler.rollback.bind(this.handler),
		);
	}
	public applyStashedOp(content: unknown): unknown {
		try {
			this.stashedOpMd = this.isAttachedAndVisible() ? createStashedOpMetadata() : undefined;
			this.handler.applyStashedOp(content);
			return this.stashedOpMd;
		} finally {
			this.stashedOpMd = undefined;
		}
	}
	public submit(contents: unknown, metadata: unknown): void {
		if (this.stashedOpMd === undefined) {
			this.submitFn(contents, metadata);
		} else {
			this.stashedOpMd.push({ contents, metadata });
		}
	}
}
```

### channelContext: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:1-213`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export const attributesBlobKey = ".attributes";
export interface IChannelContext {
	getChannel(): Promise<IChannel>;
	setConnectionState(connected: boolean, clientId?: string);
	processMessages(messageCollection: IRuntimeMessageCollection): void;
	summarize(
		fullTree?: boolean,
		trackState?: boolean,
		telemetryContext?: ITelemetryContext,
	): Promise<ISummarizeResult>;
	reSubmit(content: unknown, localOpMetadata: unknown, squash: boolean): void;
	applyStashedOp(content: unknown): unknown;
	rollback(message: unknown, localOpMetadata: unknown): void;
	getGCData(fullGC?: boolean): Promise<IGarbageCollectionData>;
	updateUsedRoutes(usedRoutes: string[]): void;
}
export interface ChannelServiceEndpoints {
	deltaConnection: ChannelDeltaConnection;
	objectStorage: ChannelStorageService;
}
export function createChannelServiceEndpoints(
	connected: boolean,
	submitFn: (content: unknown, localOpMetadata: unknown) => void,
	dirtyFn: () => void,
	isAttachedAndVisible: () => boolean,
	storageService: IRuntimeStorageService,
	logger: TelemetryLoggerExt,
	tree?: ISnapshotTree,
	extraBlobs?: Map<string, ArrayBufferLike>,
): ChannelServiceEndpoints {
	const deltaConnection = new ChannelDeltaConnection(
		connected,
		(message, localOpMetadata) => submitFn(message, localOpMetadata),
		dirtyFn,
		isAttachedAndVisible,
	);
	const objectStorage = new ChannelStorageService(tree, storageService, logger, extraBlobs);
	return {
		deltaConnection,
		objectStorage,
	};
}
export function summarizeChannel(
	channel: IChannel,
	fullTree: boolean = false,
	trackState: boolean = false,
	telemetryContext?: ITelemetryContext,
): ISummaryTreeWithStats {
	const summarizeResult = channel.getAttachSummary(fullTree, trackState, telemetryContext);
	addBlobToSummary(summarizeResult, attributesBlobKey, JSON.stringify(channel.attributes));
	return summarizeResult;
}
export async function summarizeChannelAsync(
	channel: IChannel,
	fullTree: boolean = false,
	trackState: boolean = false,
	telemetryContext?: ITelemetryContext,
	incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
): Promise<ISummaryTreeWithStats> {
	const summarizeResult = await channel.summarize(
		fullTree,
		trackState,
		telemetryContext,
		incrementalSummaryContext,
	);
	addBlobToSummary(summarizeResult, attributesBlobKey, JSON.stringify(channel.attributes));
	return summarizeResult;
}
export async function loadChannelFactoryAndAttributes(
	dataStoreContext: IFluidDataStoreContext,
	services: ChannelServiceEndpoints,
	channelId: string,
	registry: ISharedObjectRegistry,
	attachMessageType?: string,
): Promise<{ factory: IChannelFactory; attributes: IChannelAttributes }> {
	let attributes: IChannelAttributes | undefined;
	if (await services.objectStorage.contains(attributesBlobKey)) {
		attributes = await readAndParse<IChannelAttributes | undefined>(
			services.objectStorage,
			attributesBlobKey,
		);
	}
	const channelFactoryType = attributes ? attributes.type : attachMessageType;
	if (channelFactoryType === undefined) {
		throw new DataCorruptionError(
			"channelTypeNotAvailable",
			tagCodeArtifacts({
				channelId,
				dataStoreId: dataStoreContext.id,
				dataStorePackagePath: dataStoreContext.packagePath.join("/"),
				channelFactoryType,
			}),
		);
	}
	const factory = registry.get(channelFactoryType);
	if (factory === undefined) {
		throw new DataCorruptionError(
			"channelFactoryNotRegisteredForGivenType",
			tagCodeArtifacts({
				channelId,
				dataStoreId: dataStoreContext.id,
				dataStorePackagePath: dataStoreContext.packagePath.join("/"),
				channelFactoryType,
			}),
		);
	}
	attributes = attributes ?? factory.attributes;
	return { factory, attributes };
}
export async function loadChannel(
	dataStoreRuntime: IFluidDataStoreRuntime,
	attributes: IChannelAttributes,
	factory: IChannelFactory,
	services: ChannelServiceEndpoints,
	logger: TelemetryLoggerExt,
	channelId: string,
): Promise<IChannel> {
	if (
		attributes.snapshotFormatVersion !== undefined &&
		attributes.snapshotFormatVersion !== factory.attributes.snapshotFormatVersion
	) {
		logger.sendTelemetryEvent({
			eventName: "ChannelAttributesVersionMismatch",
			...tagCodeArtifacts({
				channelType: attributes.type,
				channelSnapshotVersion: `${attributes.snapshotFormatVersion}@${attributes.packageVersion}`,
				channelCodeVersion: `${factory.attributes.snapshotFormatVersion}@${factory.attributes.packageVersion}`,
			}),
		});
	}
	return factory.load(dataStoreRuntime, channelId, services, attributes);
}
```

### localChannelContext: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:1-402`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export abstract class LocalChannelContextBase implements IChannelContext {
	private globallyVisible = false;
	protected pendingMessagesState: IPendingMessagesState = {
		messageCollections: [],
		pendingCount: 0,
	};
	constructor(
		protected readonly id: string,
		protected readonly runtime: IFluidDataStoreRuntime,
		protected readonly services: Lazy<ChannelServiceEndpoints>,
		private readonly channelP: Promise<IChannel>,
		private _channel?: IChannel,
	) {
		assert(!this.id.includes("/"), 0x30f );
	}
	protected get isGloballyVisible(): boolean {
		return this.globallyVisible;
	}
	public async getChannel(): Promise<IChannel> {
		if (this._channel === undefined) {
			return this.channelP.then((c) => (this._channel = c));
		}
		return this.channelP;
	}
	public get isLoaded(): boolean {
		return this._channel !== undefined;
	}
	public setConnectionState(connected: boolean, clientId?: string): void {
		if (this.globallyVisible && this.isLoaded) {
			this.services.value.deltaConnection.setConnectionState(connected);
		}
	}
	processMessages(messageCollection: IRuntimeMessageCollection): void {
		assert(
			this.globallyVisible,
			0x2d3 ,
		);
		if (this.isLoaded) {
			this.services.value.deltaConnection.processMessages(messageCollection);
		} else {
			assert(
				!messageCollection.local,
				0x189 ,
			);
			const propsCopy = {
				...messageCollection,
				messagesContent: [...messageCollection.messagesContent],
			};
			this.pendingMessagesState.messageCollections.push(propsCopy);
		}
	}
	public reSubmit(content: unknown, localOpMetadata: unknown, squash: boolean): void {
		assert(this.isLoaded, 0x18a );
		assert(
			this.globallyVisible,
			0x2d4 ,
		);
		this.services.value.deltaConnection.reSubmit(content, localOpMetadata, squash);
	}
	public rollback(content: unknown, localOpMetadata: unknown): void {
		assert(this.isLoaded, 0x2ee );
		assert(
			this.globallyVisible,
			0x2ef ,
		);
		this.services.value.deltaConnection.rollback(content, localOpMetadata);
	}
	public abstract applyStashedOp(content: unknown): unknown;
	public async summarize(
		fullTree: boolean = false,
		trackState: boolean = false,
		telemetryContext?: ITelemetryContext,
	): Promise<ISummarizeResult> {
		const channel = await this.getChannel();
		return summarizeChannelAsync(channel, fullTree, trackState, telemetryContext);
	}
	public getAttachSummary(telemetryContext?: ITelemetryContext): ISummarizeResult {
		assert(
			this._channel !== undefined,
			0x18d ,
		);
		return summarizeChannel(
			this._channel,
			true ,
			false ,
			telemetryContext,
		);
	}
	public getAttachGCData(telemetryContext?: ITelemetryContext): IGarbageCollectionData {
		assert(
			this._channel !== undefined,
			0x8fd ,
		);
		return this._channel.getGCData( true);
	}
	public makeVisible(): void {
		if (this.globallyVisible) {
			throw new Error("Channel is already globally visible");
		}
		if (this.isLoaded) {
			assert(!!this._channel, 0x192 );
			this._channel.connect(this.services.value);
		}
		this.globallyVisible = true;
	}
	public async getGCData(fullGC: boolean = false): Promise<IGarbageCollectionData> {
		const channel = await this.getChannel();
		return channel.getGCData(fullGC);
	}
	public updateUsedRoutes(usedRoutes: string[]): void {
	}
}
export class RehydratedLocalChannelContext extends LocalChannelContextBase {
	private readonly dirtyFn: () => void;
	constructor(
		id: string,
		registry: ISharedObjectRegistry,
		runtime: IFluidDataStoreRuntime,
		dataStoreContext: IFluidDataStoreContext,
		storageService: IRuntimeStorageService,
		logger: TelemetryLoggerExt,
		submitFn: (content: unknown, localOpMetadata: unknown) => void,
		dirtyFn: (address: string) => void,
		private readonly snapshotTree: ISnapshotTree,
		extraBlob?: Map<string, ArrayBufferLike>,
	) {
		let channelType: string | undefined;
		const subLogger = createChildLogger({
			logger,
			namespace: "RehydratedLocalChannelContext",
			properties: {
				all: {
					...tagCodeArtifacts({ channelId: id, channelType: () => channelType }),
				},
			},
		});
		super(
			id,
			runtime,
			new Lazy(() => {
				const blobMap: Map<string, ArrayBufferLike> = new Map<string, ArrayBufferLike>(
					extraBlob,
				);
				const clonedSnapshotTree = cloneSnapshotTree(this.snapshotTree);
				if (this.isSnapshotInOldFormatAndCollectBlobs(clonedSnapshotTree, blobMap)) {
					this.sanitizeSnapshot(clonedSnapshotTree);
				}
				return createChannelServiceEndpoints(
					dataStoreContext.connected,
					submitFn,
					this.dirtyFn,
					() => this.isGloballyVisible,
					storageService,
					subLogger,
					clonedSnapshotTree,
					blobMap,
				);
			}),
			new LazyPromise<IChannel>(async () => {
				try {
					const { attributes, factory } = await loadChannelFactoryAndAttributes(
						dataStoreContext,
						this.services.value,
						this.id,
						registry,
					);
					channelType = attributes.type;
					const channel = await loadChannel(
						runtime,
						attributes,
						factory,
						this.services.value,
						subLogger,
						this.id,
					);
					for (const messageCollection of this.pendingMessagesState.messageCollections) {
						this.services.value.deltaConnection.processMessages(messageCollection);
					}
					return channel;
				} catch (error) {
					const errorWrapped = DataProcessingError.wrapIfUnrecognized(
						error,
						"rehydratedLocalChannelContextFailedToLoadChannel",
					);
					errorWrapped.addTelemetryProperties({
						...dataStoreLoadTelemetryProps(dataStoreContext),
						...tagCodeArtifacts({ channelId: id, channelType }),
					});
					subLogger.sendErrorEvent({ eventName: "RealizeError" }, errorWrapped);
					throw errorWrapped;
				}
			}),
		);
		this.dirtyFn = () => {
			dirtyFn(id);
		};
	}
	public override applyStashedOp(content: unknown): unknown {
		return this.services.value.deltaConnection.applyStashedOp(content);
	}
	private isSnapshotInOldFormatAndCollectBlobs(
		snapshotTree: ISnapshotTreeWithBlobContents,
		blobMap: Map<string, ArrayBufferLike>,
	): boolean {
		let sanitize = false;
		const blobsContents = snapshotTree.blobsContents;
		if (blobsContents !== undefined) {
			for (const [key, value] of Object.entries(blobsContents)) {
				blobMap.set(key, value);
				if (snapshotTree.blobs[key] !== undefined) {
					sanitize = true;
				}
			}
		}
		for (const value of Object.values(snapshotTree.trees)) {
			sanitize = sanitize || this.isSnapshotInOldFormatAndCollectBlobs(value, blobMap);
		}
		return sanitize;
	}
	private sanitizeSnapshot(snapshotTree: ISnapshotTree): void {
		const blobMapInitial = new Map(Object.entries(snapshotTree.blobs));
		for (const [blobName, blobId] of blobMapInitial.entries()) {
			const blobValue = blobMapInitial.get(blobId);
			if (blobValue === undefined) {
				delete snapshotTree.blobs[blobName];
			}
		}
		for (const value of Object.values(snapshotTree.trees)) {
			this.sanitizeSnapshot(value);
		}
	}
}
export class LocalChannelContext extends LocalChannelContextBase {
	private readonly dirtyFn: () => void;
	constructor(
		public readonly channel: IChannel,
		runtime: IFluidDataStoreRuntime,
		dataStoreContext: IFluidDataStoreContext,
		storageService: IRuntimeStorageService,
		logger: TelemetryLoggerExt,
		submitFn: (content: unknown, localOpMetadata: unknown) => void,
		dirtyFn: (address: string) => void,
	) {
		super(
			channel.id,
			runtime,
			new Lazy(() => {
				return createChannelServiceEndpoints(
					dataStoreContext.connected,
					submitFn,
					this.dirtyFn,
					() => this.isGloballyVisible,
					storageService,
					logger,
				);
			}),
			Promise.resolve(channel),
			channel,
		);
		this.channel = channel;
		this.dirtyFn = () => {
			dirtyFn(channel.id);
		};
	}
	public applyStashedOp(): void {
		throw new Error("no stashed ops on local channel");
	}
}
function cloneSnapshotTree(tree: ISnapshotTree): ISnapshotTree {
	const clone = { ...tree, blobs: { ...tree.blobs }, trees: {} };
	for (const [k, v] of Object.entries(tree.trees)) {
		clone.trees[k] = cloneSnapshotTree(v);
	}
	return clone;
}
```

### remoteChannelContext: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:1-304`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class RemoteChannelContext implements IChannelContext {
	private isLoaded = false;
	private pendingMessagesState: IPendingMessagesState | undefined = {
		messageCollections: [],
		pendingCount: 0,
	};
	private readonly channelP: Promise<IChannel>;
	private channel: IChannel | undefined;
	private readonly services: ChannelServiceEndpoints;
	private readonly summarizerNode: ISummarizerNodeWithGC;
	private readonly subLogger: TelemetryLoggerExt;
	private readonly thresholdOpsCounter: ThresholdCounter;
	private static readonly pendingOpsCountThreshold = 1000;
	constructor(
		runtime: IFluidDataStoreRuntime,
		dataStoreContext: IFluidDataStoreContext,
		storageService: IRuntimeStorageService,
		submitFn: (content: unknown, localOpMetadata: unknown) => void,
		dirtyFn: (address: string) => void,
		private readonly id: string,
		baseSnapshot: ISnapshotTree,
		registry: ISharedObjectRegistry,
		extraBlobs: Map<string, ArrayBufferLike> | undefined,
		createSummarizerNode: CreateChildSummarizerNodeFn,
		attachMessageType?: string,
	) {
		assert(!this.id.includes("/"), 0x310 );
		let channelType: string | undefined;
		this.subLogger = createChildLogger({
			logger: runtime.logger,
			namespace: "RemoteChannelContext",
			properties: {
				all: {
					...tagCodeArtifacts({
						channelId: this.id,
						channelType: () => channelType,
					}),
				},
			},
		});
		this.services = createChannelServiceEndpoints(
			dataStoreContext.connected,
			submitFn,
			() => dirtyFn(this.id),
			() => runtime.attachState !== AttachState.Detached,
			storageService,
			this.subLogger,
			baseSnapshot,
			extraBlobs,
		);
		this.channelP = new LazyPromise<IChannel>(async () => {
			try {
				const { attributes, factory } = await loadChannelFactoryAndAttributes(
					dataStoreContext,
					this.services,
					this.id,
					registry,
					attachMessageType,
				);
				channelType = attributes.type;
				const channel = await loadChannel(
					runtime,
					attributes,
					factory,
					this.services,
					this.subLogger,
					this.id,
				);
				assert(
					this.pendingMessagesState !== undefined,
					0xa6c ,
				);
				for (const messageCollection of this.pendingMessagesState.messageCollections) {
					this.services.deltaConnection.processMessages(messageCollection);
				}
				this.thresholdOpsCounter.send(
					"ProcessPendingOps",
					this.pendingMessagesState.pendingCount,
				);
				this.channel = channel;
				this.pendingMessagesState = undefined;
				this.isLoaded = true;
				this.services.deltaConnection.setConnectionState(dataStoreContext.connected);
				return this.channel;
			} catch (error) {
				const errorWrapped = DataProcessingError.wrapIfUnrecognized(
					error,
					"remoteChannelContextFailedToLoadChannel",
				);
				errorWrapped.addTelemetryProperties({
					...dataStoreLoadTelemetryProps(dataStoreContext),
					...tagCodeArtifacts({ channelId: id, channelType }),
				});
				this.subLogger.sendErrorEvent({ eventName: "RealizeError" }, errorWrapped);
				throw errorWrapped;
			}
		});
		this.summarizerNode = createSummarizerNode(
			async (
				fullTree,
				trackState,
				telemetryContext,
				incrementalSummaryContext,
			): Promise<ISummarizeInternalResult> =>
				this.summarizeInternal(
					fullTree,
					trackState,
					telemetryContext,
					incrementalSummaryContext,
				),
			async (fullGC?: boolean) => this.getGCDataInternal(fullGC),
		);
		this.thresholdOpsCounter = new ThresholdCounter(
			RemoteChannelContext.pendingOpsCountThreshold,
			this.subLogger,
		);
	}
	public getChannel(): Promise<IChannel> {
		return this.channelP;
	}
	public setConnectionState(connected: boolean, clientId?: string): void {
		if (!this.isLoaded) {
			return;
		}
		this.services.deltaConnection.setConnectionState(connected);
	}
	public applyStashedOp(content: unknown): unknown {
		assert(this.isLoaded, 0x194 );
		return this.services.deltaConnection.applyStashedOp(content);
	}
	public processMessages(messageCollection: IRuntimeMessageCollection): void {
		const { envelope, messagesContent, local } = messageCollection;
		this.summarizerNode.invalidate(envelope.sequenceNumber);
		if (this.isLoaded) {
			this.services.deltaConnection.processMessages(messageCollection);
		} else {
			assert(!local, 0x195 );
			assert(
				this.pendingMessagesState !== undefined,
				0xa6d ,
			);
			this.pendingMessagesState.messageCollections.push({
				...messageCollection,
				messagesContent: [...messagesContent],
			});
			this.pendingMessagesState.pendingCount += messagesContent.length;
			this.thresholdOpsCounter.sendIfMultiple(
				"StorePendingOps",
				this.pendingMessagesState.pendingCount,
			);
		}
	}
	public reSubmit(content: unknown, localOpMetadata: unknown, squash: boolean): void {
		assert(this.isLoaded, 0x196 );
		this.services.deltaConnection.reSubmit(content, localOpMetadata, squash);
	}
	public rollback(content: unknown, localOpMetadata: unknown): void {
		assert(this.isLoaded, 0x2f0 );
		this.services.deltaConnection.rollback(content, localOpMetadata);
	}
	public async summarize(
		fullTree: boolean = false,
		trackState: boolean = true,
		telemetryContext?: ITelemetryContext,
	): Promise<ISummarizeResult> {
		return this.summarizerNode.summarize(fullTree, trackState, telemetryContext);
	}
	private async summarizeInternal(
		fullTree: boolean,
		trackState: boolean,
		telemetryContext?: ITelemetryContext,
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
	): Promise<ISummarizeInternalResult> {
		const channel = await this.getChannel();
		const summarizeResult = await summarizeChannelAsync(
			channel,
			fullTree,
			trackState,
			telemetryContext,
			incrementalSummaryContext,
		);
		return { ...summarizeResult, id: this.id };
	}
	public async getGCData(fullGC: boolean = false): Promise<IGarbageCollectionData> {
		return this.summarizerNode.getGCData(fullGC);
	}
	private async getGCDataInternal(fullGC: boolean = false): Promise<IGarbageCollectionData> {
		const channel = await this.getChannel();
		return channel.getGCData(fullGC);
	}
	public updateUsedRoutes(usedRoutes: string[]): void {
		this.summarizerNode.updateUsedRoutes([""]);
	}
}
```

### dataStoreRuntime: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1-1717`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
type PickRequired<T extends Record<never, unknown>, K extends keyof T> = Omit<T, K> &
	Required<Pick<T, K>>;
interface IFluidDataStoreContextFeaturesToTypes {
	[encodeHandlesInContainerRuntime]: IFluidDataStoreContext;
	[notifiesReadOnlyState]: PickRequired<IFluidDataStoreContext, "isReadOnly">;
}
function contextSupportsFeature<K extends keyof IFluidDataStoreContextFeaturesToTypes>(
	obj: IFluidDataStoreContext,
	feature: K,
): obj is IFluidDataStoreContextFeaturesToTypes[K] {
	const { ILayerCompatDetails } = obj as FluidObject<ILayerCompatDetails>;
	return ILayerCompatDetails?.supportedFeatures.has(feature) ?? false;
}
export enum DataStoreMessageType {
	Attach = "attach",
	ChannelOp = "op",
}
export type LocalFluidDataStoreRuntimeMessage =
	| { type: DataStoreMessageType.ChannelOp; content: IEnvelope }
	| { type: DataStoreMessageType.Attach; content: IAttachMessage };
export interface ISharedObjectRegistry {
	get(name: string): IChannelFactory | undefined;
}
const legacyTypeUrlPrefix = atob("aHR0cHM6Ly9ncmFwaC5taWNyb3NvZnQuY29tL3R5cGVzLw==");
export class LegacyTypeAwareRegistry implements ISharedObjectRegistry {
	public constructor(private readonly base: ISharedObjectRegistry) {}
	public get(name: string): IChannelFactory | undefined {
		let factory = this.base.get(name);
		if (factory !== undefined) {
			return factory;
		}
		if (name.startsWith(legacyTypeUrlPrefix)) {
			factory = this.base.get(name.slice(legacyTypeUrlPrefix.length));
		} else {
			factory = this.base.get(`${legacyTypeUrlPrefix}${name}`);
		}
		if (factory !== undefined) {
			return factory;
		}
		if (isURL(name) && name.includes("graph.microsoft")) {
			const finalSegment = name.split("/").slice(-1)[0];
			if (finalSegment !== undefined) {
				return (
					this.base.get(finalSegment) ?? this.base.get(`${legacyTypeUrlPrefix}${finalSegment}`)
				);
			}
		}
	}
}
function isURL(str: string): boolean {
	try {
		new URL(str);
		return true;
	} catch {
		return false;
	}
}
const defaultPolicies: IFluidDataStorePolicies = {
	readonlyInStagingMode: false,
};
function initializePendingOpCount(): { value: number } {
	let value = 0;
	return {
		get value() {
			return value;
		},
		set value(newValue: number) {
			assert(newValue >= 0, 0xbbd );
			value = newValue;
		},
	};
}
export class FluidDataStoreRuntime
	extends TypedEventEmitter<IFluidDataStoreRuntimeEvents>
	implements IFluidDataStoreChannel, IFluidDataStoreRuntime, IFluidHandleContext
{
	public readonly entryPoint: IFluidHandleInternal<FluidObject>;
	public get connected(): boolean {
		return this.dataStoreContext.connected;
	}
	public readonly policies: IFluidDataStorePolicies;
	public readonly isReadOnly = (): boolean => this._readonly;
	public get clientId(): string | undefined {
		return this.dataStoreContext.clientId;
	}
	public get clientDetails(): IClientDetails {
		return this.dataStoreContext.clientDetails;
	}
	public get isAttached(): boolean {
		return this.attachState !== AttachState.Detached;
	}
	public get attachState(): AttachState {
		return this._attachState;
	}
	public get absolutePath(): string {
		return generateHandleContextPath(this.id, this.routeContext);
	}
	public get routeContext(): IFluidHandleContext {
		return this.dataStoreContext.IFluidHandleContext;
	}
	public get idCompressor(): IIdCompressor | undefined {
		return this.dataStoreContext.idCompressor;
	}
	public get IFluidHandleContext(): this {
		return this;
	}
	public get rootRoutingContext(): this {
		return this;
	}
	public get channelsRoutingContext(): this {
		return this;
	}
	public get objectsRoutingContext(): this {
		return this;
	}
	private localOpActivity: "applyStashed" | "rollback" | undefined = undefined;
	public get activeLocalOperationActivity(): "applyStashed" | "rollback" | undefined {
		return this.localOpActivity;
	}
	private _disposed = false;
	public get disposed(): boolean {
		return this._disposed;
	}
	private readonly contexts = new Map<string, IChannelContext>();
	private readonly pendingAttach = new Set<string>();
	private readonly deferredAttached = new Deferred<void>();
	private readonly localChannelContextQueue = new Map<string, LocalChannelContextBase>();
	private readonly notBoundedChannelContextSet = new Set<string>();
	private _attachState: AttachState;
	public visibilityState: VisibilityState;
	private readonly pendingHandlesToMakeVisible: Set<IFluidHandleInternal> = new Set();
	public readonly id: string;
	public readonly options: Record<string | number, any>;
	public readonly deltaManagerInternal: IDeltaManager<
		ISequencedDocumentMessage,
		IDocumentMessage
	>;
	private readonly sharedObjectRegistry: ISharedObjectRegistry;
	private readonly quorum: IQuorumClients;
	private readonly audience: IAudience;
	private readonly mc: MonitoringContext;
	public get logger(): ITelemetryLoggerExt {
		return toITelemetryLoggerExt(this.mc.logger);
	}
	private localChangesTelemetryCount: number;
	public readonly ILayerCompatDetails?: unknown = dataStoreCompatDetailsForRuntime;
	private readonly submitMessagesWithoutEncodingHandles: boolean;
	public readonly minVersionForCollab: OldestSupportedClientVersion;
	public readonly oldestSupportedClient?: OldestSupportedClientVersion;
	public constructor(
		private readonly dataStoreContext: IFluidDataStoreContext,
		sharedObjectRegistry: ISharedObjectRegistry,
		existing: boolean,
		provideEntryPoint: (runtime: IFluidDataStoreRuntime) => Promise<FluidObject>,
		policies?: Partial<IFluidDataStorePolicies>,
	) {
		super();
		this.sharedObjectRegistry = new LegacyTypeAwareRegistry(sharedObjectRegistry);
		assert(
			!dataStoreContext.id.includes("/"),
			0x30e ,
		);
		this.mc = createChildMonitoringContext({
			logger: dataStoreContext.baseLogger,
			namespace: "FluidDataStoreRuntime",
			properties: {
				all: {
					dataStoreVersion: pkgVersion,
					...dataStoreLoadTelemetryProps(dataStoreContext),
					inStagingMode: () => this.inStagingMode,
					isDirty: () => this.isDirty,
				},
			},
		});
		const { ILayerCompatDetails: runtimeCompatDetails } =
			dataStoreContext as FluidObject<ILayerCompatDetails>;
		validateRuntimeCompatibility(runtimeCompatDetails, this.dispose.bind(this), this.mc);
		if (contextSupportsFeature(dataStoreContext, notifiesReadOnlyState)) {
			this._readonly = dataStoreContext.isReadOnly();
		} else {
			this._readonly = this.dataStoreContext.deltaManager.readOnlyInfo.readonly === true;
			this.dataStoreContext.deltaManager.on("readonly", (readonly) =>
				this.notifyReadOnlyState(readonly),
			);
		}
		this.policies = { ...defaultPolicies, ...policies };
		this.submitMessagesWithoutEncodingHandles = contextSupportsFeature(
			dataStoreContext,
			encodeHandlesInContainerRuntime,
		);
		debugAssert(() => this.submitMessagesWithoutEncodingHandles !== undefined);
		this.id = dataStoreContext.id;
		this.options = dataStoreContext.options;
		this.deltaManagerInternal = dataStoreContext.deltaManager;
		this.quorum = dataStoreContext.getQuorum();
		this.audience = dataStoreContext.getAudience();
		const tree = dataStoreContext.baseSnapshot;
		if (tree?.trees !== undefined) {
			for (const [path, subtree] of Object.entries(tree.trees)) {
				if (path === "_search") {
					continue;
				}
				let channelContext: RemoteChannelContext | RehydratedLocalChannelContext;
				if (dataStoreContext.isLocalDataStore) {
					channelContext = this.createRehydratedLocalChannelContext(path, subtree);
					if (dataStoreContext.attachState === AttachState.Detached) {
						this.localChannelContextQueue.set(path, channelContext);
					} else {
						channelContext.makeVisible();
					}
				} else {
					channelContext = new RemoteChannelContext(
						this,
						dataStoreContext,
						dataStoreContext.storage,
						(content, localOpMetadata) => this.submitChannelOp(path, content, localOpMetadata),
						(address: string) => this.setChannelDirty(address),
						path,
						subtree,
						this.sharedObjectRegistry,
						undefined ,
						this.dataStoreContext.getCreateChildSummarizerNodeFn(path, {
							type: CreateSummarizerNodeSource.FromSummary,
						}),
					);
				}
				this.contexts.set(path, channelContext);
			}
		}
		this.entryPoint = new FluidObjectHandle<FluidObject>(
			new LazyPromise(async () =>
				provideEntryPoint(this).catch((error) => {
					let packagePath: readonly string[] = [];
					try {
						packagePath = this.dataStoreContext.packagePath;
					} catch {
					}
					const errorWrapped = DataProcessingError.wrapIfUnrecognized(
						error,
						"entryPointInitialization",
					);
					errorWrapped.addTelemetryProperties(
						dataStoreLoadTelemetryProps({ id: this.dataStoreContext.id, packagePath }),
					);
					this.mc.logger.sendErrorEvent(
						{ eventName: "EntryPointInitializationFailure" },
						errorWrapped,
					);
					throw errorWrapped;
				}),
			),
			"",
			this.objectsRoutingContext,
		);
		this.attachListener();
		this._attachState = dataStoreContext.attachState;
		if (existing) {
			this.visibilityState =
				dataStoreContext.attachState === AttachState.Detached
					? VisibilityState.LocallyVisible
					: VisibilityState.GloballyVisible;
		} else {
			this.visibilityState = VisibilityState.NotVisible;
		}
		if (existing) {
			this.deferredAttached.resolve();
		}
		this.localChangesTelemetryCount =
			this.mc.config.getNumber("Fluid.Telemetry.LocalChangesTelemetryCount") ?? 10;
		this.oldestSupportedClient =
			this.dataStoreContext.oldestSupportedClient ?? this.dataStoreContext.minVersionForCollab;
		this.minVersionForCollab = this.oldestSupportedClient;
	}
	public get inStagingMode(): boolean {
		return this.dataStoreContext.containerRuntime.inStagingMode;
	}
	public get isDirty(): boolean {
		return this.pendingOpCount.value > 0;
	}
	get deltaManager(): IDeltaManagerErased {
		return toDeltaManagerErased(this.deltaManagerInternal);
	}
	public dispose(): void {
		if (this._disposed) {
			return;
		}
		this._disposed = true;
		this.emit("dispose");
		this.removeAllListeners();
	}
	public async resolveHandle(request: IRequest): Promise<IResponse> {
		return this.request(request);
	}
	public async request(request: IRequest): Promise<IResponse> {
		try {
			const parser = RequestParser.create(request);
			if (parser.pathParts.length === 0 && request.headers?.viaHandle === true) {
				return { mimeType: "fluid/object", status: 200, value: await this.entryPoint.get() };
			}
			const id = parser.pathParts[0];
			if (id === "_channels" || id === "_custom") {
				return await this.request(parser.createSubRequest(1));
			}
			if (id !== undefined) {
				const context = this.contexts.get(id);
				if (context !== undefined && parser.isLeaf(1)) {
					try {
						const channel = await context.getChannel();
						return { mimeType: "fluid/object", status: 200, value: channel };
					} catch (error) {
						this.mc.logger.sendErrorEvent({ eventName: "GetChannelFailedInRequest" }, error);
						return createResponseError(500, `Failed to get Channel: ${error}`, request);
					}
				}
			}
			return create404Response(request);
		} catch (error) {
			return exceptionToResponse(error);
		}
	}
	public async getChannel(id: string): Promise<IChannel> {
		this.verifyNotClosed();
		const context = this.contexts.get(id);
		if (context === undefined) {
			throw new LoggingError("Channel does not exist");
		}
		return context.getChannel();
	}
	protected validateChannelId(id: string): void {
		if (id.includes("/")) {
			throw new UsageError(`Id cannot contain slashes: ${id}`);
		}
		if (id.startsWith("_")) {
			throw new UsageError(`Id cannot start with underscore: ${id}`);
		}
	}
	public addChannel(channel: IChannel): void {
		const id = channel.id;
		this.validateChannelId(id);
		this.verifyNotClosed();
		assert(!this.contexts.has(id), 0x865 );
		const type = channel.attributes.type;
		const factory = this.sharedObjectRegistry.get(channel.attributes.type);
		if (factory === undefined) {
			throw new Error(`Channel Factory ${type} not registered`);
		}
		this.createChannelContext(channel);
		this.identifyLocalChangeInSummarizer("DDSCreatedInSummarizer", id, type);
	}
	public createChannel(idArg: string | undefined, type: string): IChannel {
		let id: string;
		if (idArg === undefined) {
			if (this.mc.config.getBoolean("Fluid.Runtime.DisableShortIds") === true) {
				id = uuid();
			} else {
				if (this.visibilityState === VisibilityState.GloballyVisible) {
					const res =
						this.dataStoreContext.containerRuntime.generateDocumentUniqueId?.() ?? uuid();
					id = typeof res === "number" ? encodeCompactIdToString(2 * res + 1, "_") : res;
				} else {
					id = encodeCompactIdToString(2 * this.contexts.size, "_");
				}
			}
			assert(!id.includes("/"), 0x8fc );
		} else {
			id = idArg;
			this.validateChannelId(id);
		}
		this.verifyNotClosed();
		assert(!this.contexts.has(id), 0x179 );
		assert(type !== undefined, 0x209 );
		const factory = this.sharedObjectRegistry.get(type);
		if (factory === undefined) {
			throw new Error(`Channel Factory ${type} not registered`);
		}
		const channel = factory.create(this, id);
		this.createChannelContext(channel);
		this.identifyLocalChangeInSummarizer("DDSCreatedInSummarizer", id, type);
		return channel;
	}
	private createChannelContext(channel: IChannel): void {
		this.notBoundedChannelContextSet.add(channel.id);
		const context = new LocalChannelContext(
			channel,
			this,
			this.dataStoreContext,
			this.dataStoreContext.storage,
			extractTelemetryLoggerExt(this.logger),
			(content, localOpMetadata) => this.submitChannelOp(channel.id, content, localOpMetadata),
			(address: string) => this.setChannelDirty(address),
		);
		this.contexts.set(channel.id, context);
	}
	private createRehydratedLocalChannelContext(
		id: string,
		tree: ISnapshotTree,
		flatBlobs?: Map<string, ArrayBufferLike>,
	): RehydratedLocalChannelContext {
		return new RehydratedLocalChannelContext(
			id,
			this.sharedObjectRegistry,
			this,
			this.dataStoreContext,
			this.dataStoreContext.storage,
			extractTelemetryLoggerExt(this.logger),
			(content, localOpMetadata) => this.submitChannelOp(id, content, localOpMetadata),
			(address: string) => this.setChannelDirty(address),
			tree,
			flatBlobs,
		);
	}
	public bindChannel(channel: IChannel): void {
		assert(
			this.notBoundedChannelContextSet.has(channel.id),
			0x17b ,
		);
		this.notBoundedChannelContextSet.delete(channel.id);
		if (this.isAttached) {
			this.makeChannelLocallyVisible(channel);
			return;
		}
		if (this.pendingHandlesToMakeVisible.has(toFluidHandleInternal(channel.handle))) {
			return;
		}
		this.bind(channel.handle);
		if (!this.localChannelContextQueue.has(channel.id)) {
			this.localChannelContextQueue.set(
				channel.id,
				this.contexts.get(channel.id) as LocalChannelContextBase,
			);
		}
	}
	public makeVisibleAndAttachGraph(): void {
		if (this.visibilityState !== VisibilityState.NotVisible) {
			return;
		}
		this.visibilityState = VisibilityState.LocallyVisible;
		for (const handle of this.pendingHandlesToMakeVisible) {
			handle.attachGraph();
		}
		this.pendingHandlesToMakeVisible.clear();
		this.dataStoreContext.makeLocallyVisible();
	}
	public attachGraph(): void {
		this.makeVisibleAndAttachGraph();
	}
	public bind(handle: IFluidHandle): void {
		if (this.visibilityState !== VisibilityState.NotVisible) {
			toFluidHandleInternal(handle).attachGraph();
			return;
		}
		this.pendingHandlesToMakeVisible.add(toFluidHandleInternal(handle));
	}
	public setConnectionState(connected: boolean, clientId?: string): void {
		this.verifyNotClosed();
		for (const [, object] of this.contexts) {
			object.setConnectionState(connected, clientId);
		}
		raiseConnectedEvent(extractTelemetryLoggerExt(this.logger), this, connected, clientId);
	}
	private _readonly: boolean;
	public notifyReadOnlyState(readonly: boolean): void {
		this.verifyNotClosed();
		if (readonly !== this._readonly) {
			this._readonly = readonly;
			this.emit("readonly", readonly);
		}
	}
	public getQuorum(): IQuorumClients {
		return this.quorum;
	}
	public getAudience(): IAudience {
		return this.audience;
	}
	public async uploadBlob(
		blob: ArrayBufferLike,
		signal?: AbortSignal,
	): Promise<IFluidHandle<ArrayBufferLike>> {
		this.verifyNotClosed();
		return this.dataStoreContext.uploadBlob(blob, signal);
	}
	private createRemoteChannelContext(
		attachMessage: IAttachMessage,
		summarizerNodeParams: CreateChildSummarizerNodeParam,
	): RemoteChannelContext {
		const flatBlobs = new Map<string, ArrayBufferLike>();
		const snapshotTree = buildSnapshotTree(attachMessage.snapshot.entries, flatBlobs);
		return new RemoteChannelContext(
			this,
			this.dataStoreContext,
			this.dataStoreContext.storage,
			(content, localContentMetadata) =>
				this.submitChannelOp(attachMessage.id, content, localContentMetadata),
			(address: string) => this.setChannelDirty(address),
			attachMessage.id,
			snapshotTree,
			this.sharedObjectRegistry,
			flatBlobs,
			this.dataStoreContext.getCreateChildSummarizerNodeFn(
				attachMessage.id,
				summarizerNodeParams,
			),
			attachMessage.type,
		);
	}
	private processChannelMessages(messageCollection: IRuntimeMessageCollection): void {
		this.verifyNotClosed();
		let currentAddress: string | undefined;
		let currentMessagesContent: IRuntimeMessagesContent[] = [];
		const { messagesContent, local, envelope } = messageCollection;
		const sendBunchedMessages = (): void => {
			if (currentAddress === undefined) {
				return;
			}
			const channelContext = this.contexts.get(currentAddress);
			assert(!!channelContext, 0xa6b );
			channelContext.processMessages({
				envelope,
				messagesContent: currentMessagesContent,
				local,
			});
			currentMessagesContent = [];
		};
		for (const { contents, ...restOfMessagesContent } of messagesContent) {
			const contentsEnvelope = contents as IEnvelope;
			if (currentAddress !== contentsEnvelope.address) {
				sendBunchedMessages();
			}
			currentMessagesContent.push({
				contents: contentsEnvelope.contents,
				...restOfMessagesContent,
			});
			currentAddress = contentsEnvelope.address;
		}
		sendBunchedMessages();
	}
	private processAttachMessages(messageCollection: IRuntimeMessageCollection): void {
		const { envelope, messagesContent, local } = messageCollection;
		for (const { contents } of messagesContent) {
			const attachMessage = contents as IAttachMessage;
			const id = attachMessage.id;
			processAttachMessageGCData(attachMessage.snapshot, (nodeId, toPath) => {
				const fromPath = `/${this.id}/${id}${nodeId === "/" ? "" : nodeId}`;
				this.dataStoreContext.addedGCOutboundRoute(fromPath, toPath, envelope.timestamp);
			});
			if (local) {
				assert(
					this.pendingAttach.delete(id),
					0x17c ,
				);
			} else {
				assert(!this.contexts.has(id), 0x17d );
				const summarizerNodeParams = {
					type: CreateSummarizerNodeSource.FromAttach,
					sequenceNumber: envelope.sequenceNumber,
					snapshot: attachMessage.snapshot,
				};
				const remoteChannelContext = this.createRemoteChannelContext(
					attachMessage,
					summarizerNodeParams,
				);
				this.contexts.set(id, remoteChannelContext);
			}
		}
	}
	public processMessages(messageCollection: IRuntimeMessageCollection): void {
		this.verifyNotClosed();
		const { envelope, local, messagesContent } = messageCollection;
		if (local) {
			this.pendingOpCount.value -= messagesContent.length;
		}
		try {
			switch (envelope.type) {
				case DataStoreMessageType.ChannelOp: {
					this.processChannelMessages(messageCollection);
					break;
				}
				case DataStoreMessageType.Attach: {
					this.processAttachMessages(messageCollection);
					break;
				}
				default:
			}
		} catch (error) {
			throw DataProcessingError.wrapIfUnrecognized(
				error,
				"fluidDataStoreRuntimeFailedToProcessMessage",
				envelope,
			);
		}
		for (const { contents, clientSequenceNumber } of messagesContent) {
			this.emit("op", { ...envelope, contents, clientSequenceNumber });
		}
	}
	public processSignal(message: IInboundSignalMessage, local: boolean): void {
		this.emit("signal", message, local);
	}
	private isChannelAttached(id: string): boolean {
		return (
			!this.notBoundedChannelContextSet.has(id) &&
			!this.localChannelContextQueue.has(id) &&
			!this.pendingAttach.has(id)
		);
	}
	private getOutboundRoutes(): string[] {
		const outboundRoutes: string[] = [];
		for (const [contextId] of this.contexts) {
			outboundRoutes.push(`${this.absolutePath}/${contextId}`);
		}
		return outboundRoutes;
	}
	private updateGCNodes(builder: GCDataBuilder): void {
		builder.addRouteToAllNodes(this.absolutePath);
		builder.addNode("/", this.getOutboundRoutes());
	}
	public async summarize(
		fullTree: boolean = false,
		trackState: boolean = true,
		telemetryContext?: ITelemetryContext,
	): Promise<ISummaryTreeWithStats> {
		const summaryBuilder = new SummaryTreeBuilder();
		await this.visitContextsDuringSummary(
			async (contextId: string, context: IChannelContext) => {
				const contextSummary = await context.summarize(fullTree, trackState, telemetryContext);
				summaryBuilder.addWithStats(contextId, contextSummary);
			},
		);
		return summaryBuilder.getSummaryTree();
	}
	public async getGCData(fullGC: boolean = false): Promise<IGarbageCollectionData> {
		const builder = new GCDataBuilder();
		await this.visitContextsDuringSummary(
			async (contextId: string, context: IChannelContext) => {
				const contextGCData = await context.getGCData(fullGC);
				builder.prefixAndAddNodes(contextId, contextGCData.gcNodes);
			},
		);
		this.updateGCNodes(builder);
		return builder.getGCData();
	}
	public updateUsedRoutes(usedRoutes: string[]): void {
		const usedContextRoutes = unpackChildNodesUsedRoutes(usedRoutes);
		for (const [id] of usedContextRoutes) {
			assert(
				this.contexts.has(id),
				0x17e ,
			);
		}
		for (const [contextId, context] of this.contexts) {
			context.updateUsedRoutes(usedContextRoutes.get(contextId) ?? []);
		}
	}
	public getAttachSummary(telemetryContext?: ITelemetryContext): ISummaryTreeWithStats {
		const summaryBuilder = new SummaryTreeBuilder();
		this.visitLocalBoundContextsDuringAttach(
			(contextId: string, context: LocalChannelContextBase) => {
				let summaryTree: ISummaryTreeWithStats;
				if (context.isLoaded) {
					const contextSummary = context.getAttachSummary(telemetryContext);
					assert(
						contextSummary.summary.type === SummaryType.Tree,
						0x180 ,
					);
					summaryTree = { stats: contextSummary.stats, summary: contextSummary.summary };
				} else {
					assert(
						!!this.dataStoreContext.baseSnapshot,
						0x181 ,
					);
					summaryTree = convertSnapshotTreeToSummaryTree(
						this.dataStoreContext.baseSnapshot.trees[contextId]!,
					);
				}
				summaryBuilder.addWithStats(contextId, summaryTree);
			},
		);
		return summaryBuilder.getSummaryTree();
	}
	public getAttachGCData(telemetryContext?: ITelemetryContext): IGarbageCollectionData {
		const gcDataBuilder = new GCDataBuilder();
		this.visitLocalBoundContextsDuringAttach(
			(contextId: string, context: LocalChannelContextBase) => {
				if (context.isLoaded) {
					const contextGCData = context.getAttachGCData(telemetryContext);
					gcDataBuilder.prefixAndAddNodes(contextId, contextGCData.gcNodes);
				}
			},
		);
		this.updateGCNodes(gcDataBuilder);
		return gcDataBuilder.getGCData();
	}
	private async visitContextsDuringSummary(
		visitor: (contextId: string, context: IChannelContext) => Promise<void>,
	): Promise<void> {
		for (const [contextId, context] of this.contexts) {
			const isAttached = this.isChannelAttached(contextId);
			assert(isAttached, 0x17f );
			await visitor(contextId, context);
		}
	}
	private visitLocalBoundContextsDuringAttach(
		visitor: (contextId: string, context: LocalChannelContextBase) => void,
	): void {
		assert(
			this.visibilityState === VisibilityState.LocallyVisible,
			0xc2c ,
		);
		const visitedContexts = new Set<string>();
		let visitedLength = -1;
		while (visitedLength !== visitedContexts.size) {
			visitedLength = visitedContexts.size;
			for (const [contextId, context] of this.contexts) {
				if (!(context instanceof LocalChannelContextBase)) {
					throw new LoggingError("Should only be called with local channel handles");
				}
				if (
					!visitedContexts.has(contextId) &&
					!this.notBoundedChannelContextSet.has(contextId)
				) {
					visitor(contextId, context);
					visitedContexts.add(contextId);
				}
			}
		}
	}
	public submitSignal(type: string, content: unknown, targetClientId?: string): void {
		this.verifyNotClosed();
		this.dataStoreContext.submitSignal(type, content, targetClientId);
	}
	public async waitAttached(): Promise<void> {
		return this.deferredAttached.promise;
	}
	private makeChannelLocallyVisible(channel: IChannel): void {
		this.verifyNotClosed();
		if (channel.handle.isAttached) {
			return;
		}
		toFluidHandleInternal(channel.handle).attachGraph();
		assert(
			this.isAttached,
			0x182 ,
		);
		assert(
			this.visibilityState === VisibilityState.GloballyVisible,
			0x2d0 ,
		);
		const summarizeResult = summarizeChannel(
			channel,
			true ,
			false ,
		);
		const gcData = channel.getGCData( true);
		addBlobToSummary(summarizeResult, gcDataBlobKey, JSON.stringify(gcData));
		const snapshot = convertSummaryTreeToITree(summarizeResult.summary);
		const message: IAttachMessage = {
			id: channel.id,
			snapshot,
			type: channel.attributes.type,
		};
		this.pendingAttach.add(channel.id);
		this.submit({ type: DataStoreMessageType.Attach, content: message });
		const context = this.contexts.get(channel.id) as LocalChannelContextBase;
		context.makeVisible();
	}
	private submitChannelOp(address: string, contents: unknown, localOpMetadata: unknown): void {
		const envelope: IEnvelope = { address, contents };
		this.verifyNotClosed();
		this.submit({ type: DataStoreMessageType.ChannelOp, content: envelope }, localOpMetadata);
	}
	private readonly pendingOpCount: { value: number } = initializePendingOpCount();
	private submit(
		message: LocalFluidDataStoreRuntimeMessage,
		localOpMetadata: unknown = undefined,
	): void {
		this.dataStoreContext.submitMessage(message.type, message.content, localOpMetadata);
		++this.pendingOpCount.value;
	}
	public reSubmit(
		type: DataStoreMessageType,
		content: any,
		localOpMetadata: unknown,
		squash: boolean,
	): void {
		this.verifyNotClosed();
		--this.pendingOpCount.value;
		switch (type) {
			case DataStoreMessageType.ChannelOp: {
				const envelope = content as IEnvelope;
				const channelContext = this.contexts.get(envelope.address);
				assert(!!channelContext, 0x183 );
				channelContext.reSubmit(envelope.contents, localOpMetadata, squash);
				break;
			}
			case DataStoreMessageType.Attach: {
				this.submit({ type, content }, localOpMetadata);
				break;
			}
			default: {
				unreachableCase(type);
			}
		}
	}
	public rollback?(
		type: DataStoreMessageType,
		content: any,
		localOpMetadata: unknown,
	): void {
		this.verifyNotClosed();
		assert(
			!this.localOpActivity,
			0xca2 ,
		);
		this.localOpActivity = "rollback";
		try {
			--this.pendingOpCount.value;
			switch (type) {
				case DataStoreMessageType.ChannelOp: {
					const envelope = content as IEnvelope;
					const channelContext = this.contexts.get(envelope.address);
					assert(!!channelContext, 0x2ed );
					channelContext.rollback(envelope.contents, localOpMetadata);
					break;
				}
				default: {
					throw new LoggingError(`Can't rollback ${type} message`);
				}
			}
		} finally {
			this.localOpActivity = undefined;
		}
	}
	public async applyStashedOp(content: any): Promise<unknown> {
		assert(
			!this.localOpActivity,
			0xca3 ,
		);
		this.localOpActivity = "applyStashed";
		try {
			++this.pendingOpCount.value;
			const type = content?.type as DataStoreMessageType;
			switch (type) {
				case DataStoreMessageType.Attach: {
					const attachMessage = content.content as IAttachMessage;
					const flatBlobs = new Map<string, ArrayBufferLike>();
					const snapshotTree = buildSnapshotTree(attachMessage.snapshot.entries, flatBlobs);
					const channelContext = this.createRehydratedLocalChannelContext(
						attachMessage.id,
						snapshotTree,
						flatBlobs,
					);
					await channelContext.getChannel();
					this.contexts.set(attachMessage.id, channelContext);
					if (this.attachState === AttachState.Detached) {
						this.localChannelContextQueue.set(attachMessage.id, channelContext);
					} else {
						channelContext.makeVisible();
						this.pendingAttach.add(attachMessage.id);
					}
					return;
				}
				case DataStoreMessageType.ChannelOp: {
					const envelope = content.content as IEnvelope;
					const channelContext = this.contexts.get(envelope.address);
					assert(!!channelContext, 0x184 );
					await channelContext.getChannel();
					return channelContext.applyStashedOp(envelope.contents);
				}
				default: {
					unreachableCase(type);
				}
			}
		} finally {
			this.localOpActivity = undefined;
		}
	}
	private setChannelDirty(address: string): void {
		this.verifyNotClosed();
		this.dataStoreContext.setChannelDirty(address);
	}
	private attachListener(): void {
		this.setMaxListeners(Number.MAX_SAFE_INTEGER);
		(this.dataStoreContext as any).once?.("attaching", () => {
			this.setAttachState(AttachState.Attaching);
		});
		(this.dataStoreContext as any).once?.("attached", () => {
			this.setAttachState(AttachState.Attached);
		});
	}
	private verifyNotClosed(): void {
		if (this._disposed) {
			throw new LoggingError("Runtime is closed");
		}
	}
	private identifyLocalChangeInSummarizer(
		eventName: string,
		channelId: string,
		channelType: string,
	): void {
		if (this.clientDetails.type !== "summarizer" || this.localChangesTelemetryCount <= 0) {
			return;
		}
		this.mc.logger.sendTelemetryEvent({
			eventName,
			...tagCodeArtifacts({
				channelType,
				channelId,
			}),
			stack: generateStack(30),
		});
		this.localChangesTelemetryCount--;
	}
	public setAttachState(attachState: AttachState.Attaching | AttachState.Attached): void {
		switch (attachState) {
			case AttachState.Attaching: {
				this.attachGraph();
				this._attachState = AttachState.Attaching;
				assert(
					this.visibilityState === VisibilityState.LocallyVisible,
					0x2d1 ,
				);
				this.visibilityState = VisibilityState.GloballyVisible;
				for (const [, channel] of this.localChannelContextQueue) {
					channel.makeVisible();
				}
				this.localChannelContextQueue.clear();
				this.deferredAttached.resolve();
				this.emit("attaching");
				break;
			}
			case AttachState.Attached: {
				assert(
					this.visibilityState === VisibilityState.GloballyVisible,
					0x2d2 ,
				);
				this._attachState = AttachState.Attached;
				this.emit("attached");
				break;
			}
			default: {
				unreachableCase(attachState, "unreached");
			}
		}
	}
}
export const mixinRequestHandler = (
	requestHandler: (request: IRequest, runtime: FluidDataStoreRuntime) => Promise<IResponse>,
	Base: typeof FluidDataStoreRuntime = FluidDataStoreRuntime,
): typeof FluidDataStoreRuntime =>
	class RuntimeWithRequestHandler extends Base {
		public async request(request: IRequest): Promise<IResponse> {
			const response = await super.request(request);
			if (response.status === 404) {
				return requestHandler(request, this);
			}
			return response;
		}
	} as typeof FluidDataStoreRuntime;
export const mixinSummaryHandler = (
	handler: (
		runtime: FluidDataStoreRuntime,
		setCurrentSummarizeStep: (currentStep: string) => void,
	) => Promise<{ path: string[]; content: string } | undefined>,
	Base: typeof FluidDataStoreRuntime = FluidDataStoreRuntime,
): typeof FluidDataStoreRuntime =>
	class RuntimeWithSummarizerHandler extends Base {
		private addBlob(summary: ISummaryTreeWithStats, path: string[], content: string): void {
			const firstName = path.shift();
			if (firstName === undefined) {
				throw new LoggingError("Path can't be empty");
			}
			let blob: ISummaryTree | ISummaryBlob = {
				type: SummaryType.Blob,
				content,
			};
			summary.stats.blobNodeCount++;
			summary.stats.totalBlobSize += content.length;
			for (const name of path.reverse()) {
				blob = {
					type: SummaryType.Tree,
					tree: { [name]: blob },
				};
				summary.stats.treeNodeCount++;
			}
			summary.summary.tree[firstName] = blob;
		}
		async summarize(
			fullTree: boolean = false,
			trackState: boolean = true,
			telemetryContext?: ITelemetryContext,
		): Promise<ISummaryTreeWithStats> {
			const summary = await super.summarize(fullTree, trackState, telemetryContext);
			try {
				const content = await handler(this, (currentStep: string) =>
					telemetryContext?.set(
						currentSummarizeStepPrefix,
						currentSummarizeStepPropertyName,
						`mixinSummaryHandler:${currentStep}`,
					),
				);
				if (content !== undefined) {
					this.addBlob(summary, content.path, content.content);
				}
			} catch (error) {
				throw DataProcessingError.wrapIfUnrecognized(error, "mixinSummaryHandler");
			}
			return summary;
		}
	} as typeof FluidDataStoreRuntime;
```



## 5. Invariants and asserts

Assertions below terminate the current operation; do not convert them into successful no-ops. Ordered contracts above retain the exact condition at each failure site.

- `0x9d7`: id is undefined in ChannelStorageService.readBlob(). `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelStorageService.ts:49`
- `0x177`: "Missing delta handler". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:77`
- `0x178`: "Missing delta handler on attach". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:92`
- `0x30f`: Channel context ID cannot contain slashes. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:60`
- `0x2d3`: "Local channel must be globally visible when processing op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:92`
- `0x189`: "Should always be remote because a local dds shouldn't generate ops before loading". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:103`
- `0x18a`: "Channel should be loaded to resubmit ops". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:114`
- `0x2d4`: "Local channel must be globally visible when resubmitting op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:117`
- `0x2ee`: "Channel should be loaded to rollback ops". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:122`
- `0x2ef`: "Local channel must be globally visible when rolling back op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:125`
- `0x18d`: "Channel should be loaded to take snapshot". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:155`
- `0x8fd`: Local Channel should be loaded before being attached. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:174`
- `0x192`: "Channel should be there if loaded!!". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/localChannelContext.ts:187`
- `0x310`: Channel context ID cannot contain slashes. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:75`
- `0xa6c`: pending messages state is undefined. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:127`
- `0x194`: "Remote channel must be loaded when rebasing op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:199`
- `0x195`: "Remote channel must not be local when processing op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:214`
- `0xa6d`: pending messages queue is undefined. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:217`
- `0x196`: "Remote channel must be loaded when resubmitting op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:232`
- `0x2f0`: "Remote channel must be loaded when rolling back op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/remoteChannelContext.ts:238`
- `0xbbd`: pendingOpCount must be non-negative. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:249`
- `0x30e`: Id cannot contain slashes. DataStoreContext should have validated this.. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:415`
- `0x865`: addChannel() with existing ID. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:678`
- `0x8fc`: slash. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:718`
- `0x179`: "createChannel() with existing ID". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:725`
- `0x209`: "Factory Type should be defined". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:727`
- `0x17b`: "Channel to be bound should be in not bounded set". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:781`
- `0xa6b`: Channel context not found. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:941`
- `0x17c`: "Unexpected attach (local) channel OP". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:989`
- `0x17d`: "Unexpected attach channel OP". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:992`
- `0x17e`: "Used route does not belong to any known context". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1157`
- `0x180`: "getAttachSummary should always return a tree". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1177`
- `0x181`: "BaseSnapshot should be there as detached container loaded from snapshot". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1186`
- `0x17f`: "Not expecting detached channels during summarize". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1232`
- `0xc2c`: The data store should be locally visible when generating attach summary. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1246`
- `0x182`: "Data store should be attached to attach the channel.". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1307`
- `0x2d0`: "Data store should be globally visible to attach channels.". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1311`
- `0x183`: "There should be a channel context for the op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1393`
- `0xca2`: localOpActivity must be undefined when entering rollback. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1433`
- `0x2ed`: "There should be a channel context for the op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1445`
- `0xca3`: localOpActivity must be undefined when entering applyStashedOp. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1464`
- `0x184`: "There should be a channel context for the op". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1501`
- `0x2d1`: "Data store should be locally visible before it can become globally visible.". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1599`
- `0x2d2`: "Data store should be globally visible when its attached.". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1617`

## 6. JS-semantics hazards

Contexts Maps preserve registration order; never regroup a batch by dictionary key. Attach can re-enter binding synchronously: preserve no-op replacement and visibility flags. Queued arrays must be copied while objects inside remain shared. Private stashed metadata uses Symbol identity and is not a JSON payload. Emit attaching before deferred promise continuation even though resolve occurs first. Path IDs cannot contain slash. Preserve absent attributes compatibility and do not treat version mismatch telemetry as a load error. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:922-1045` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:17-154` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1581-1627` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:150-213`

## 7. Test assets to reuse

- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/channelStorageService.spec.ts:1-83` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/dataStoreLayerCompatValidation.spec.ts:1-294` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/dataStoreRuntime.spec.ts:1-678` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/localChannelContext.spec.ts:1-149` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/remoteChannelContext.spec.ts:1-234` — reuse the oracle cases and expected values under the same operation order.

## 8. Open questions

None. The ordered contracts include the source behavior even where it is surprising; they are not a redesign.
