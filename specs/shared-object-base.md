# shared-object-base — native Swift port contract (3.11.0)

## 1. Role

Common DDS lifecycle, submission, handle serialization, summary and GC bridge to datastore channel services. Concrete DDSes supply their operations, storage bodies and mutation hooks. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:73-94`

## 2. Surface used by other packages

`SharedObjectCore`, `SharedObject`, `FluidSerializer`/`IFluidSerializer`, handle serialization helpers, `createSingleBlobSummary`, `SharedObjectHandle`, `createSharedObjectKind` and kernel-based kind construction. Exact interfaces and implementation signatures below are the port boundary. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/index.ts:6-45`

### types: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/types.ts:1-78`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export interface ISharedObjectEvents extends IErrorEvent {
	(
		event: "pre-op",
		listener: (
			op: ISequencedDocumentMessage,
			local: boolean,
			target: IEventThisPlaceHolder,
		) => void,
	);
	(
		event: "op",
		listener: (
			op: ISequencedDocumentMessage,
			local: boolean,
			target: IEventThisPlaceHolder,
		) => void,
	);
}
export interface ISharedObject<TEvent extends ISharedObjectEvents = ISharedObjectEvents>
	extends IChannel,
		IEventProvider<TEvent> {
	bindToContext(): void;
}
```

### valueType: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/valueType.ts:1-21`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export enum ValueType {
	Shared,
	Plain,
}
```



## 3. Wire and persisted formats

### Encoded handles

Normal handle object emission order: `type`, `url`; pending-payload variant adds `payloadPending: true` last. Literal example `{"type":"__fluid_handle__","url":"/store/dds"}`; pending example `{"type":"__fluid_handle__","url":"/_blobs/b1","payloadPending":true}`. `url` is absolute on write. Absence and false are not emitted in place of true. Recognition checks **only** `value?.type === "__fluid_handle__"`, not URL validity or an exact property set. Reader supports old relative URL strings by resolving against serializer context; encoded URL starting `/` is unchanged. Pending decoding uses strict `===true`. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:33-115` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:141-160`

### Operations and metadata

DDS content shape belongs to the concrete DDS. `submitLocalMessage(content, localOpMetadata=undefined)` sends content through delta connection; metadata is retained locally and returned on own acknowledgment/resubmit, not serialized into message contents. The enclosing datastore envelope is `{address: channelId, contents: encodedDDSContent}`. Example for an arbitrary concrete content `{"address":"counter","contents":{"incrementAmount":1}}` illustrates only the wrapping operation; SharedObject adds no DDS opcode. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:413-449` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1339-1357`

### Summary and attributes

`createSingleBlobSummary("header","x")` produces `{summary:{type:1,tree:{header:{type:2,content:"x"}}},stats:{treeNodeCount:1,blobNodeCount:1,handleNodeCount:0,totalBlobSize:1,unreferencedBlobSize:0}}`. Binary content remains a Uint8Array until storage conversion. SharedObject does not add an attributes blob itself: the datastore `summarizeChannel`/async wrapper appends `.attributes` after DDS summary generation using `JSON.stringify(channel.attributes)`. Channel fields are `type:string`, `snapshotFormatVersion:string`, optional `packageVersion:string`; original attribute object insertion order is retained, not schema-order reconstructed. An attributes object constructed in that field order with values `T`,`1`,`3.11.0` produces the exact blob `{"type":"T","snapshotFormatVersion":"1","packageVersion":"3.11.0"}`. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/utils.ts:84-96` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:48-66` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:111-148` `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/storage.ts:10-26`

GC returns `{gcNodes:{"/":string[]}}`; routes are visited handle absolute paths deduplicated in Set insertion order. A handle-free DDS produces `{"gcNodes":{"/":[]}}`. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:833-876` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/gcHandleVisitor.ts:12-33`


## 4. Behavior

### Lifecycle

Construction sets services absent, bound=false and connected=false, creates the handle and telemetry, and installs the event-listener error handler. New local creation invokes `initializeLocalCore`; it does not attach. `bindToContext` replaces itself with a no-op **before** runtime binding to prevent re-entry, calls runtime.bindChannel if not already bound, then marks bound/handles attach. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:86-340`

Load: assign services; set bound=true before `await loadCore(storage)` so loadCore observes attachment correctly; attach delta handler; mark bound/handle attach. Connect: only if services absent assign and attach handler; always mark bound/handle attach. First mark-bound replaces itself with a function which only refreshes connection state; sets bound=true; invokes `didAttach` then connection-state update immediately if runtime not detached, else registers one runtime `attaching` listener doing those steps. `isAttached=bound && runtime.attachState!=Detached`, not socket-connected. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:286-353`

A connection-state update is ignored if detached or unchanged. Otherwise store the new flag first, then onConnect/onDisconnect. No SharedObject connected/disconnected public event is synthesized by this method. Resubmit callback chooses squashed or normal hook. Default normal hook resubmits original content and metadata. Default squashed hook resolves config `Fluid.SharedObject.AllowStagingModeWithoutSquashing`, then runtime option, then true: true invokes ordinary hook, false throws unsupported. Base rollback throws unsupported. Stashed hook decodes handles then invokes concrete `applyStashedOp`; it must apply as a local edit, including submission, not merely return metadata. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:474-690`

### Submission, receiving and event order

1. Submission verifies not closed; detached does nothing. Attached prepares handles: when runtime internal `submitMessagesWithoutEncodingHandles===true`, only bind every reachable handle; otherwise serializer encodes handles and binds them. Then deltaConnection.submit(preparedContent, metadata). Dirty is likewise ignored when detached. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:423-460`
2. Receive verifies not closed, decodes **all** contents first, retaining metadata and client sequence per content. Emit `pre-op(message,local)` for every decoded content in order; invoke `processMessagesCore` **once** with the decoded collection; after success emit `op(message,local)` for every content in order. Events reconstruct messages by envelope spread then overriding contents and clientSequenceNumber. A thrown core call prevents all post-op events. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:602-649`
3. Public DDS emit is synchronous, measured; internal pre-op/op bypass only the measurement, not EventEmitter semantics. Listener exceptions become `SharedObjectEventListenerException`, attach emittedEventName telemetry, close/poison the DDS, and rethrow. Preserve first failure and no further mutations after close. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:254-284` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:695-718`

### Serialization and summaries

`encode` validates the bind handle, traverses nonnull objects, visits current node before children, treats handles as leaves and clones only changed paths. `stringify` uses JSON replacer (and therefore ordinary JS toJSON/replacer traversal), while parse uses reviver; neither is a generic Swift Codable round trip. Encoding calls bind.bind(handle) **before** producing the serialized object. Summary and attach-summary both call summarizeCore synchronously before updating blob-count and byte-size telemetry; summarize is async only in its API return. GC uses a visitor, asserts nonre-entry, sets `_isGCing`, runs processGCDataCore (default summarizeCore(visitor)), creates one root GC node, then clears `_isGCing` in finally. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:69-231` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:783-885`

The complete ordered contracts include handle graph attachment and kernel/create-kind factory forwarding, so lifecycle implementations need not reconstruct these from call sites.


### Replay expansion is part of the pending-metadata contract

ChannelDeltaConnection.applyStashedOp sets its capture to a symbol-marked empty array iff attached-and-visible, invokes handler.applyStashedOp synchronously, returns the capture array (or undefined), clears capture in finally. While capture exists, delta submit appends `{contents,metadata}` and does **not** call submitFn. The array can be empty, one or multiple entries; its symbol marker is enumerable but not a JSON field. An ordinary array is not this marker. On acknowledgment the wrapper expands entries into messages with the **original** clientSequenceNumber repeated; on resubmit/rollback it invokes the hook once per captured entry in stored order. No reversed rollback order is introduced by this wrapper. Missing rollback throws Handler doesn't support rollback. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:17-154`

For a two-content bunch A,B, successful external order is pre-op(A),pre-op(B),processMessagesCore([A,B]),op(A),op(B); contents have all been decoded before the first pre-op. Metadata is included in the core's messageContent records but not in the reconstructed event message. A decode failure prevents every pre-op; a pre-op listener failure stops before core; a core failure prevents every post-op; a post-op listener failure can occur after all state changes. These are synchronous failure boundaries, not a transaction that restores state. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:602-647`

SharedObject.getAttachSummary and summarize pass fullTree through to summarizeCore, with incrementalSummaryContext undefined for attach and supplied for summarize; trackState is accepted but unused by this synchronous base. Both update BlobCount then TotalBlobSize telemetry after the core returns. createSingleBlobSummary allocates a builder, adds one blob using the exact string/binary content, returns builder.getSummaryTree; it never JSON-stringifies the supplied content itself. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:785-831` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/utils.ts:84-92`

### serializer: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:1-231`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export interface IFluidSerializer {
	encode(value: unknown, bind: IFluidHandle): unknown;
	decode(input: unknown): unknown;
	stringify(value: unknown, bind: IFluidHandle): string;
	parse(value: string): unknown;
}
export class FluidSerializer implements IFluidSerializer {
	private readonly root: IFluidHandleContext;
	public constructor(private readonly context: IFluidHandleContext) {
		this.root = this.context;
		while (this.root.routeContext !== undefined) {
			this.root = this.root.routeContext;
		}
	}
	public get IFluidSerializer(): IFluidSerializer {
		return this;
	}
	public encode(input: unknown, bind: IFluidHandleInternal): unknown {
		assert(isISharedObjectHandle(bind), 0xb8c );
		return !!input && typeof input === "object"
			? this.recursivelyReplace(input, this.encodeValue.bind(this), bind)
			: input;
	}
	public decode(input: unknown): unknown {
		return !!input && typeof input === "object"
			? this.recursivelyReplace(input, this.decodeValue.bind(this))
			: input;
	}
	public stringify(input: unknown, bind: IFluidHandle): string {
		assert(isISharedObjectHandle(bind), 0xb8d );
		return JSON.stringify(input, (key, value) => this.encodeValue(value, bind));
	}
	public parse(input: string): unknown {
		return JSON.parse(input, (key, value) => this.decodeValue(value));
	}
	protected encodeValue(value: unknown, bind?: ISharedObjectHandle): unknown {
		if (isFluidHandle(value)) {
			assert(bind !== undefined, 0xa93 );
			return this.bindAndEncodeHandle(toFluidHandleInternal(value), bind);
		}
		return value;
	}
	protected decodeValue(value: unknown): unknown {
		if (isSerializedHandle(value)) {
			const absolutePath = value.url.startsWith("/")
				? value.url
				: generateHandleContextPath(value.url, this.context);
			return new RemoteFluidObjectHandle(
				absolutePath,
				this.root,
				value.payloadPending === true,
			);
		} else {
			return value;
		}
	}
	private recursivelyReplace<TContext = unknown>(
		input: object,
		replacer: (input: unknown, context?: TContext) => unknown,
		context?: TContext,
	): unknown {
		const maybeReplaced = replacer(input, context);
		if (isFluidHandle(input) || isFluidHandle(maybeReplaced)) {
			return maybeReplaced;
		}
		let clone: object | undefined;
		for (const key of Object.keys(input)) {
			const value: unknown = input[key];
			if (!!value && typeof value === "object") {
				const replaced = this.recursivelyReplace(value, replacer, context);
				if (replaced !== value) {
					clone ??= shallowCloneObject(input);
					clone[key] = replaced;
				}
			}
		}
		return clone ?? input;
	}
	protected bindAndEncodeHandle(
		handle: IFluidHandleInternal,
		bind: ISharedObjectHandle,
	): ISerializedHandle {
		bind.bind(handle);
		return encodeHandleForSerialization(handle);
	}
}
```

### handle: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/handle.ts:1-139`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export interface ISharedObjectHandle extends IFluidHandleInternal<ISharedObject> {
	bind(handle: IFluidHandleInternal): void;
}
export function isISharedObjectHandle(handle: unknown): handle is ISharedObjectHandle {
	return isFluidHandle(handle) && typeof (handle as ISharedObjectHandle).bind === "function";
}
export class SharedObjectHandle
	extends FluidObjectHandle<ISharedObject>
	implements ISharedObjectHandle
{
	public get isAttached(): boolean {
		return this.value.isAttached();
	}
	private get isVisible(): boolean {
		return this.isAttached || this.isLocallyVisible;
	}
	private isLocallyVisible: boolean = false;
	private readonly pendingHandles: Set<IFluidHandleInternal> = new Set();
	constructor(
		protected readonly value: ISharedObject,
		path: string,
		private readonly runtime: IFluidDataStoreRuntime,
	) {
		super(value, path, runtime.IFluidHandleContext);
	}
	public attachGraph(): void {
		if (this.isVisible) {
			return;
		}
		this.isLocallyVisible = true;
		for (const handle of this.pendingHandles) {
			handle.attachGraph();
		}
		this.pendingHandles.clear();
		this.value.bindToContext();
		super.attachGraph();
	}
	public bind(handle: IFluidHandleInternal): void {
		if (this.runtime.inStagingMode === true) {
			return;
		}
		if (this.isVisible) {
			handle.attachGraph();
			return;
		}
		this.pendingHandles.add(handle);
	}
}
```

### gcHandleVisitor: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/gcHandleVisitor.ts:1-33`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export class GCHandleVisitor extends FluidSerializer {
	private readonly visitedHandlePaths: Set<string> = new Set();
	public getVisitedHandlePaths(): string[] {
		return [...this.visitedHandlePaths];
	}
	protected bindAndEncodeHandle(handle: IFluidHandleInternal): ISerializedHandle {
		this.visitedHandlePaths.add(handle.absolutePath);
		return {
			type: "__fluid_handle__",
			url: "UNUSED (see GCHandleVisitor)",
		};
	}
}
```

### utils: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/utils.ts:1-134`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export function serializeHandles(
	value: unknown,
	serializer: IFluidSerializer,
	bind: IFluidHandle,
): string | undefined {
	return value === undefined ? value : serializer.stringify(value, bind);
}
export function makeHandlesSerializable(
	value: unknown,
	serializer: IFluidSerializer,
	bind: IFluidHandle,
): unknown {
	return serializer.encode(value, bind);
}
export function parseHandles(value: unknown, serializer: IFluidSerializer): unknown {
	return serializer.decode(value);
}
export function createSingleBlobSummary(
	key: string,
	content: string | Uint8Array,
): ISummaryTreeWithStats {
	const builder = new SummaryTreeBuilder();
	builder.addBlob(key, content);
	return builder.getSummaryTree();
}
export function bindHandles<T = unknown>(value: T, bind: IFluidHandle): T {
	const nodesToProcess: unknown[] = [value];
	const visitedNodes = new Set<unknown>();
	assert(isISharedObjectHandle(bind), 0xc85 );
	while (nodesToProcess.length > 0) {
		const node = nodesToProcess.pop();
		if (isFluidHandle(node)) {
			visitedNodes.add(node);
			bind.bind(toFluidHandleInternal(node));
		} else if (Array.isArray(node) && !visitedNodes.has(node)) {
			visitedNodes.add(node);
			for (const item of node) {
				if (isObject(item)) {
					nodesToProcess.push(item);
				}
			}
		} else if (isObject(node) && !visitedNodes.has(node)) {
			visitedNodes.add(node);
			for (const val of Object.values(node)) {
				if (isObject(val)) {
					nodesToProcess.push(val);
				}
			}
		}
	}
	return value;
}
export type IChannelView = Pick<IChannel, "id" | "attributes" | "isAttached">;
```

### sharedObject: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:1-1069`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
interface ProcessTelemetryProperties {
	sequenceDifference: number;
}
export abstract class SharedObjectCore<
		TEvent extends ISharedObjectEvents = ISharedObjectEvents,
	>
	extends EventEmitterWithErrorHandling<TEvent>
	implements ISharedObject<TEvent>
{
	public get IFluidLoadable(): this {
		return this;
	}
	private readonly opProcessingHelper: SampledTelemetryHelper<
		void,
		ProcessTelemetryProperties
	>;
	private readonly callbacksHelper: SampledTelemetryHelper<boolean>;
	public readonly handle: IFluidHandleInternal;
	protected readonly logger: ITelemetryLoggerExt;
	private readonly mc: MonitoringContext;
	private _connected = false;
	private services: IChannelServices | undefined;
	private _isBoundToContext: boolean = false;
	private closeError?: ReturnType<typeof DataProcessingError.wrapIfUnrecognized>;
	public get connected(): boolean {
		return this._connected;
	}
	constructor(
		public id: string,
		protected runtime: IFluidDataStoreRuntime,
		public readonly attributes: IChannelAttributes,
	) {
		super((event: EventEmitterEventType, e: unknown) =>
			this.eventListenerErrorHandler(event, e),
		);
		assert(!id.includes("/"), 0x304 );
		this.handle = new SharedObjectHandle(this, id, runtime);
		const internalLogger = createChildLogger({
			logger: runtime.logger,
			properties: {
				all: {
					sharedObjectId: uuid(),
					...tagCodeArtifacts({
						ddsType: this.attributes.type,
					}),
				},
			},
		});
		this.logger = internalLogger;
		this.mc = loggerToMonitoringContext(internalLogger);
		const { opProcessingHelper, callbacksHelper } = this.setUpSampledTelemetryHelpers();
		this.opProcessingHelper = opProcessingHelper;
		this.callbacksHelper = callbacksHelper;
	}
	protected get deltaManager(): IDeltaManager<ISequencedDocumentMessage, IDocumentMessage> {
		return toDeltaManagerInternal(this.runtime.deltaManager);
	}
	private setUpSampledTelemetryHelpers(): {
		opProcessingHelper: SampledTelemetryHelper<void, ProcessTelemetryProperties>;
		callbacksHelper: SampledTelemetryHelper<boolean>;
	} {
		assert(
			this.mc !== undefined && this.logger !== undefined,
			0x349 ,
		);
		const opProcessingHelper = new SampledTelemetryHelper<void, ProcessTelemetryProperties>(
			{
				eventName: "ddsOpProcessing",
				category: "performance",
			},
			extractTelemetryLoggerExt(this.logger),
			this.mc.config.getNumber("Fluid.SharedObject.OpProcessingTelemetrySampling") ?? 1000,
			true,
			new Map<string, ITelemetryBaseProperties>([
				["local", { localOp: true }],
				["remote", { localOp: false }],
			]),
		);
		const callbacksHelper = new SampledTelemetryHelper<boolean>(
			{
				eventName: "ddsEventCallbacks",
				category: "performance",
			},
			extractTelemetryLoggerExt(this.logger),
			this.mc.config.getNumber("Fluid.SharedObject.DdsCallbacksTelemetrySampling") ?? 1000,
			true,
		);
		this.runtime.once("dispose", () => {
			this.callbacksHelper.dispose();
			this.opProcessingHelper.dispose();
		});
		return { opProcessingHelper, callbacksHelper };
	}
	private closeWithError(error: IFluidErrorBase | undefined): void {
		if (this.closeError === undefined) {
			this.closeError = error;
		}
	}
	private verifyNotClosed(): void {
		if (this.closeError !== undefined) {
			throw this.closeError;
		}
	}
	private eventListenerErrorHandler(event: EventEmitterEventType, e: unknown): void {
		const error = DataProcessingError.wrapIfUnrecognized(
			e,
			"SharedObjectEventListenerException",
		);
		error.addTelemetryProperties({ emittedEventName: String(event) });
		this.closeWithError(error);
		throw error;
	}
	private setBoundAndHandleAttach(): void {
		this.setBoundAndHandleAttach = () => this.setConnectionState(this.runtime.connected);
		this._isBoundToContext = true;
		const runDidAttach: () => void = () => {
			this.didAttach();
			this.setConnectionState(this.runtime.connected);
		};
		if (this.isAttached()) {
			runDidAttach();
		} else {
			this.runtime.once("attaching", runDidAttach);
		}
	}
	public async load(services: IChannelServices): Promise<void> {
		this.services = services;
		this._isBoundToContext = true;
		await this.loadCore(services.objectStorage);
		this.attachDeltaHandler();
		this.setBoundAndHandleAttach();
	}
	public initializeLocal(): void {
		this.initializeLocalCore();
	}
	public bindToContext(): void {
		this.bindToContext = () => {};
		if (!this._isBoundToContext) {
			this.runtime.bindChannel(this);
			this.setBoundAndHandleAttach();
		}
	}
	public connect(services: IChannelServices): void {
		if (this.services === undefined) {
			this.services = services;
			this.attachDeltaHandler();
		}
		this.setBoundAndHandleAttach();
	}
	public isAttached(): boolean {
		return this._isBoundToContext && this.runtime.attachState !== AttachState.Detached;
	}
	public abstract getAttachSummary(
		fullTree?: boolean,
		trackState?: boolean,
		telemetryContext?: ITelemetryContext,
	): ISummaryTreeWithStats;
	public abstract summarize(
		fullTree?: boolean,
		trackState?: boolean,
		telemetryContext?: ITelemetryContext,
	): Promise<ISummaryTreeWithStats>;
	public abstract getGCData(fullGC?: boolean): IGarbageCollectionData;
	protected abstract loadCore(services: IChannelStorageService): Promise<void>;
	protected initializeLocalCore(): void {
		return;
	}
	protected didAttach(): void {
		return;
	}
	protected abstract processMessagesCore(messagesCollection: IRuntimeMessageCollection): void;
	protected abstract onDisconnect(): void;
	protected abstract get serializer(): IFluidSerializer;
	protected submitLocalMessage(content: unknown, localOpMetadata: unknown = undefined): void {
		this.verifyNotClosed();
		if (this.isAttached()) {
			const contentToSubmit = this.#prepareMessage(content);
			this.#submitMessage(contentToSubmit, localOpMetadata);
		}
	}
	#prepareMessage(content: unknown): unknown {
		const onlyBind =
			(this.runtime as IFluidDataStoreRuntimeInternalConfig)
				.submitMessagesWithoutEncodingHandles === true;
		return onlyBind
			? bindHandles(content, this.handle)
			: makeHandlesSerializable(content, this.serializer, this.handle);
	}
	#submitMessage(content: unknown, localOpMetadata: unknown): void {
		this.services!.deltaConnection.submit(content, localOpMetadata);
	}
	protected dirty(): void {
		if (!this.isAttached()) {
			return;
		}
		this.services!.deltaConnection.dirty();
	}
	protected onConnect(): void {}
	protected reSubmitCore(content: unknown, localOpMetadata: unknown): void {
		this.submitLocalMessage(content, localOpMetadata);
	}
	protected reSubmitSquashed(content: unknown, localOpMetadata: unknown): void {
		const allowStagingModeWithoutSquashing =
			loggerToMonitoringContext(this.logger).config.getBoolean(
				"Fluid.SharedObject.AllowStagingModeWithoutSquashing",
			) ??
			(this.runtime.options.allowStagingModeWithoutSquashing as boolean | undefined) ??
			true;
		if (allowStagingModeWithoutSquashing) {
			this.reSubmitCore(content, localOpMetadata);
		} else {
			this.throwUnsupported("reSubmitSquashed");
		}
	}
	protected async newAckBasedPromise<T>(
		executor: (
			resolve: (value: T | PromiseLike<T>) => void,
			reject: (reason?: unknown) => void,
		) => void,
	): Promise<T> {
		let rejectBecauseDispose: () => void;
		return new Promise<T>((resolve, reject) => {
			rejectBecauseDispose = () =>
				reject(
					new Error("FluidDataStoreRuntime disposed while this ack-based Promise was pending"),
				);
			if (this.runtime.disposed) {
				rejectBecauseDispose();
				return;
			}
			this.runtime.on("dispose", rejectBecauseDispose);
			executor(resolve, reject);
		}).finally(() => {
			this.runtime.off("dispose", rejectBecauseDispose);
		});
	}
	readonly #deltaHandler: IDeltaHandler = {
		processMessages: (messagesCollection: IRuntimeMessageCollection) => {
			this.processMessages(messagesCollection);
		},
		setConnectionState: (connected: boolean) => {
			this.setConnectionState(connected);
		},
		reSubmit: (content: unknown, localOpMetadata: unknown, squash: boolean) => {
			this.reSubmit(content, localOpMetadata, squash);
		},
		applyStashedOp: (content: unknown): void => {
			this.applyStashedOp(parseHandles(content, this.serializer));
		},
		rollback: (content: unknown, localOpMetadata: unknown) => {
			this.rollback(content, localOpMetadata);
		},
	};
	private attachDeltaHandler(): void {
		assert(
			this.services !== undefined,
			0x07a ,
		);
		this.services.deltaConnection.attach(this.#deltaHandler);
	}
	private setConnectionState(connected: boolean): void {
		if (!this.isAttached() || this._connected === connected) {
			return;
		}
		this._connected = connected;
		if (connected) {
			this.onConnect();
		} else {
			this.onDisconnect();
		}
	}
	private processMessages(messagesCollection: IRuntimeMessageCollection): void {
		this.verifyNotClosed();
		const { envelope, local, messagesContent } = messagesCollection;
		const decodedMessagesContent: IRuntimeMessagesContent[] = [];
		for (const { contents, localOpMetadata, clientSequenceNumber } of messagesContent) {
			const decodedMessageContent: IRuntimeMessagesContent = {
				contents: parseHandles(contents, this.serializer),
				localOpMetadata,
				clientSequenceNumber,
			};
			decodedMessagesContent.push(decodedMessageContent);
		}
		const emitEvents = (event: "pre-op" | "op"): void => {
			for (const { contents, clientSequenceNumber } of decodedMessagesContent) {
				const message: ISequencedDocumentMessage = {
					...envelope,
					contents,
					clientSequenceNumber,
				};
				this.emitInternal(event, message, local);
			}
		};
		emitEvents("pre-op");
		this.opProcessingHelper.measure(
			(): ICustomData<ProcessTelemetryProperties> => {
				const decodedMessagesCollection: IRuntimeMessageCollection = {
					envelope,
					local,
					messagesContent: decodedMessagesContent,
				};
				this.processMessagesCore(decodedMessagesCollection);
				const telemetryProperties: ProcessTelemetryProperties = {
					sequenceDifference: envelope.sequenceNumber - envelope.referenceSequenceNumber,
				};
				return {
					customData: telemetryProperties,
				};
			},
			local ? "local" : "remote",
		);
		emitEvents("op");
	}
	private reSubmit(content: unknown, localOpMetadata: unknown, squash: boolean): void {
		if (squash) {
			this.reSubmitSquashed(content, localOpMetadata);
		} else {
			this.reSubmitCore(content, localOpMetadata);
		}
	}
	protected rollback(content: unknown, localOpMetadata: unknown): void {
		this.throwUnsupported("rollback");
	}
	protected abstract applyStashedOp(content: unknown): void;
	public emit(event: EventEmitterEventType, ...args: any[]): boolean {
		return this.callbacksHelper.measure(() => {
			return super.emit(event, ...args);
		});
	}
	private emitInternal(event: EventEmitterEventType, ...args: unknown[]): boolean {
		return super.emit(event, ...args);
	}
	private throwUnsupported(featureName: string): never {
		throw new LoggingError("Unsupported DDS feature", {
			featureName,
			...tagCodeArtifacts({ ddsType: this.attributes.type }),
		});
	}
}
export abstract class SharedObject<
	TEvent extends ISharedObjectEvents = ISharedObjectEvents,
> extends SharedObjectCore<TEvent> {
	private _isGCing: boolean = false;
	private readonly _serializer: IFluidSerializer;
	protected get serializer(): IFluidSerializer {
		assert(
			!this._isGCing,
			0x075 ,
		);
		return this._serializer;
	}
	constructor(
		id: string,
		runtime: IFluidDataStoreRuntime,
		attributes: IChannelAttributes,
		private readonly telemetryContextPrefix: string,
	) {
		super(id, runtime, attributes);
		this._serializer = new FluidSerializer(this.runtime.channelsRoutingContext);
	}
	public getAttachSummary(
		fullTree: boolean = false,
		trackState: boolean = false,
		telemetryContext?: ITelemetryContext,
	): ISummaryTreeWithStats {
		const result = this.summarizeCore(
			this.serializer,
			telemetryContext,
			undefined ,
			fullTree,
		);
		this.incrementTelemetryMetric(
			blobCountPropertyName,
			result.stats.blobNodeCount,
			telemetryContext,
		);
		this.incrementTelemetryMetric(
			totalBlobSizePropertyName,
			result.stats.totalBlobSize,
			telemetryContext,
		);
		return result;
	}
	public async summarize(
		fullTree: boolean = false,
		trackState: boolean = false,
		telemetryContext?: ITelemetryContext,
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
	): Promise<ISummaryTreeWithStats> {
		const result = this.summarizeCore(
			this.serializer,
			telemetryContext,
			incrementalSummaryContext,
			fullTree,
		);
		this.incrementTelemetryMetric(
			blobCountPropertyName,
			result.stats.blobNodeCount,
			telemetryContext,
		);
		this.incrementTelemetryMetric(
			totalBlobSizePropertyName,
			result.stats.totalBlobSize,
			telemetryContext,
		);
		return result;
	}
	public getGCData(fullGC: boolean = false): IGarbageCollectionData {
		assert(
			!this._isGCing,
			0x078 ,
		);
		this._isGCing = true;
		let gcData: IGarbageCollectionData;
		try {
			const handleVisitor = new GCHandleVisitor(this.runtime.channelsRoutingContext);
			this.processGCDataCore(handleVisitor);
			gcData = { gcNodes: { "/": handleVisitor.getVisitedHandlePaths() } };
			assert(
				this._isGCing,
				0x079 ,
			);
		} finally {
			this._isGCing = false;
		}
		return gcData;
	}
	protected processGCDataCore(serializer: IFluidSerializer): void {
		this.summarizeCore(serializer);
	}
	protected abstract summarizeCore(
		serializer: IFluidSerializer,
		telemetryContext?: ITelemetryContext,
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
		fullTree?: boolean,
	): ISummaryTreeWithStats;
	private incrementTelemetryMetric(
		propertyName: string,
		incrementBy: number,
		telemetryContext?: ITelemetryContext,
	): void {
		if (telemetryContext !== undefined) {
			assert(
				"get" in telemetryContext && typeof telemetryContext.get === "function",
				0x97e ,
			);
			const prevTotal = ((telemetryContext as TelemetryContext).get(
				this.telemetryContextPrefix,
				propertyName,
			) ?? 0) as number;
			telemetryContext.set(this.telemetryContextPrefix, propertyName, prevTotal + incrementBy);
		}
	}
}
export interface ISharedObjectKind<TSharedObject> {
	getFactory(): IChannelFactory<TSharedObject>;
	create(runtime: IFluidDataStoreRuntime, id?: string): TSharedObject;
}
export interface SharedObjectKind<out TSharedObject = unknown>
	extends ErasedType<readonly ["SharedObjectKind", TSharedObject]> {
	is(value: IFluidLoadable): value is IFluidLoadable & TSharedObject;
}
export type SharedObjectKey<T> = RegistryKey<SharedObjectKindAlpha<T>, SharedObjectKindAlpha>;
export interface SharedObjectKindAlpha<out TSharedObject = unknown>
	extends SharedObjectKind<TSharedObject>,
		SharedObjectKey<TSharedObject> {}
export function createSharedObjectKind<TSharedObject>(
	factory: (new () => IChannelFactory<TSharedObject>) & { readonly Type: string },
): ISharedObjectKind<TSharedObject> & SharedObjectKind<TSharedObject> {
	return createSharedObjectKindAlpha(factory);
}
export function createSharedObjectKindAlpha<TSharedObject>(
	factory: (new () => IChannelFactory<TSharedObject>) & { readonly Type: string },
): ISharedObjectKind<TSharedObject> & SharedObjectKindAlpha<TSharedObject> {
	const result: ISharedObjectKind<TSharedObject> &
		Omit<SharedObjectKindAlpha<TSharedObject>, "brand"> = {
		getFactory(): IChannelFactory<TSharedObject> {
			return new factory();
		},
		create(runtime: IFluidDataStoreRuntime, id?: string): TSharedObject {
			return runtime.createChannel(id, factory.Type) as TSharedObject;
		},
		is(value: IFluidLoadable): value is IFluidLoadable & TSharedObject {
			return isChannel(value) && value.attributes.type === factory.Type;
		},
		type: factory.Type,
		adapt: (value: SharedObjectKindAlpha): SharedObjectKindAlpha<TSharedObject> => {
			if (value === resultFinal) {
				return resultFinal;
			}
			if (value.type === result.type) {
				throw new UsageError(`Conflicting SharedObjectKinds with same type: ${result.type}`);
			}
			throw new UsageError(
				`Mismatched SharedObjectKind type. Expected: ${result.type}, got: ${value.type}`,
			);
		},
	};
	const resultFinal = result as typeof result & SharedObjectKindAlpha<TSharedObject>;
	return resultFinal;
}
function isChannel(loadable: IFluidLoadable): loadable is IChannel {
	return (loadable as IChannel).attributes !== undefined;
}
```

### sharedObjectKernel: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObjectKernel.ts:1-503`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export interface SharedKernel {
	summarizeCore(
		serializer: IFluidSerializer,
		telemetryContext: ITelemetryContext | undefined,
		incrementalSummaryContext: IExperimentalIncrementalSummaryContext | undefined,
		fullTree?: boolean,
	): ISummaryTreeWithStats;
	onDisconnect(): void;
	reSubmitCore(content: unknown, localOpMetadata: unknown): void;
	applyStashedOp(content: unknown): void;
	processMessagesCore(messagesCollection: IRuntimeMessageCollection): void;
	rollback?(content: unknown, localOpMetadata: unknown): void;
	didAttach?(): void;
}
class SharedObjectFromKernel<
	TOut extends object,
	TEvent extends ISharedObjectEvents,
> extends SharedObject<TEvent> {
	#lazyData: FactoryOut<TOut> | undefined = undefined;
	readonly #kernelArgs: KernelArgs;
	public constructor(
		id: string,
		runtime: IFluidDataStoreRuntime,
		attributes: IChannelAttributes,
		public readonly factory: SharedKernelFactory<TOut>,
		telemetryContextPrefix: string,
	) {
		super(id, runtime, attributes, telemetryContextPrefix);
		const minVersionForCollab: OldestSupportedClientVersion | undefined =
			(runtime as IFluidDataStoreRuntimeInternalConfig).oldestSupportedClient ??
			(runtime as IFluidDataStoreRuntimeInternalConfig).minVersionForCollab;
		assert(minVersionForCollab !== undefined, 0xcee );
		this.#kernelArgs = {
			sharedObject: this,
			serializer: this.serializer,
			submitLocalMessage: (op, localOpMetadata) =>
				this.submitLocalMessage(op, localOpMetadata),
			eventEmitter: this,
			logger: extractTelemetryLoggerExt(this.logger),
			idCompressor: runtime.idCompressor,
			lastSequenceNumber: () => this.deltaManager.lastSequenceNumber,
			initialSequenceNumber: this.deltaManager.initialSequenceNumber,
			minVersionForCollab,
			oldestSupportedClient: minVersionForCollab,
		};
	}
	protected override summarizeCore(
		serializer: IFluidSerializer,
		telemetryContext?: ITelemetryContext,
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
		fullTree?: boolean,
	): ISummaryTreeWithStats {
		return this.#kernel.summarizeCore(
			serializer,
			telemetryContext,
			incrementalSummaryContext,
			fullTree,
		);
	}
	protected override initializeLocalCore(): void {
		this.#initializeData(this.factory.create(this.#kernelArgs));
	}
	#initializeData(data: FactoryOut<TOut>): void {
		assert(
			this.#lazyData === undefined,
			0xb99 ,
		);
		this.#lazyData = data;
		mergeAPIs(this, data.view);
	}
	get #kernel(): SharedKernel {
		return (this.#lazyData ?? fail(0xcb0 )).kernel;
	}
	protected override async loadCore(storage: IChannelStorageService): Promise<void> {
		this.#initializeData(await this.factory.loadCore(this.#kernelArgs, storage));
	}
	protected override onDisconnect(): void {
		this.#kernel.onDisconnect();
	}
	protected override reSubmitCore(content: unknown, localOpMetadata: unknown): void {
		this.#kernel.reSubmitCore(content, localOpMetadata);
	}
	protected override applyStashedOp(content: unknown): void {
		this.#kernel.applyStashedOp(content);
	}
	protected override processMessagesCore(messagesCollection: IRuntimeMessageCollection): void {
		this.#kernel.processMessagesCore(messagesCollection);
	}
	protected override rollback(content: unknown, localOpMetadata: unknown): void {
		if (this.#kernel.rollback === undefined) {
			super.rollback(content, localOpMetadata);
		} else {
			this.#kernel.rollback(content, localOpMetadata);
		}
	}
	protected override didAttach(): void {
		this.#kernel.didAttach?.();
	}
}
export const thisWrap: unique symbol = Symbol("selfWrap");
export interface FactoryOut<T extends object> {
	readonly kernel: SharedKernel;
	readonly view: T;
}
export interface SharedKernelFactory<T extends object> {
	create(args: KernelArgs): FactoryOut<T>;
	loadCore(args: KernelArgs, storage: IChannelStorageService): Promise<FactoryOut<T>>;
}
export interface KernelArgs {
	readonly sharedObject: IChannelView & IFluidLoadable;
	readonly serializer: IFluidSerializer;
	readonly submitLocalMessage: (op: unknown, localOpMetadata: unknown) => void;
	readonly eventEmitter: TypedEventEmitter<ISharedObjectEvents>;
	readonly logger: TelemetryLoggerExt;
	readonly idCompressor: IIdCompressor | undefined;
	readonly lastSequenceNumber: () => number;
	readonly initialSequenceNumber: number;
	readonly minVersionForCollab: OldestSupportedClientVersion;
	readonly oldestSupportedClient: OldestSupportedClientVersion;
}
export function mergeAPIs<const Base extends object, const Extra extends object>(
	base: Base,
	extra: Extra,
): asserts base is Base & Extra {
	for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(extra))) {
		assert(!Reflect.has(base, key), 0xb9a );
		let getter: () => unknown;
		if (typeof descriptor.value === "function") {
			const fromExtra: () => Extra | Base = descriptor.value;
			getter = () => forwardMethod(fromExtra, extra, base);
			Object.defineProperty(extra, key, { ...descriptor, writable: false });
		} else {
			getter = () => extra[key];
		}
		Object.defineProperty(base, key, {
			configurable: false,
			enumerable: descriptor.enumerable,
			get: getter,
		});
	}
}
function forwardMethod<TArgs extends [], TReturn>(
	f: (...args: TArgs) => TReturn,
	oldThis: TReturn,
	newThis: TReturn,
): (...args: TArgs) => TReturn {
	if (thisWrap in f) {
		return (...args: TArgs) => {
			const result = f.call(oldThis, ...args);
			assert(result === oldThis, 0xb9b );
			return newThis;
		};
	} else {
		return f.bind(oldThis);
	}
}
export interface SharedObjectOptions<T extends object> {
	readonly type: string;
	readonly attributes: IChannelAttributes;
	readonly factory: SharedKernelFactory<Omit<T, keyof ISharedObject>>;
	readonly telemetryContextPrefix: string;
}
function makeChannelFactory<T extends object>(options: SharedObjectOptions<T>) {
	class ChannelFactory implements IChannelFactory<T> {
		public static readonly Type = options.type;
		public static readonly Attributes: IChannelAttributes = options.attributes;
		public get type(): string {
			return ChannelFactory.Type;
		}
		public get attributes(): IChannelAttributes {
			return ChannelFactory.Attributes;
		}
		public async load(
			runtime: IFluidDataStoreRuntime,
			id: string,
			services: IChannelServices,
			attributes: IChannelAttributes,
		): Promise<T & IChannel> {
			const shared = new SharedObjectFromKernel(
				id,
				runtime,
				attributes,
				options.factory,
				options.telemetryContextPrefix,
			);
			await shared.load(services);
			return shared as unknown as T & IChannel;
		}
		public create(runtime: IFluidDataStoreRuntime, id: string): T & IChannel {
			const shared = new SharedObjectFromKernel(
				id,
				runtime,
				ChannelFactory.Attributes,
				options.factory,
				options.telemetryContextPrefix,
			);
			shared.initializeLocal();
			return shared as unknown as T & IChannel;
		}
	}
	return ChannelFactory;
}
export function makeSharedObjectKind<T extends object>(
	options: SharedObjectOptions<T>,
): ISharedObjectKind<T> & SharedObjectKindAlpha<T> {
	return createSharedObjectKindAlpha<T>(makeChannelFactory(options));
}
```

### dataStoreKind: exact ordered contract

Source: `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/dataStoreKind.ts:1-301`. The following is normative TypeScript notation for the port: execute statements in order, preserve guards, defaults, mutation-before-callback order, and exception/finally boundaries. Imports and comments alone are removed; no algorithm statements are omitted.

```typescript
export type SharedObjectRegistry = () => Promise<
	Registry<SharedObjectKindAlpha<IFluidLoadable>>
>;
export function sharedObjectRegistryFromIterable(
	entries: Iterable<
		| SharedObjectKindAlpha<IFluidLoadable>
		| { type: string; kind: () => Promise<SharedObjectKindAlpha<IFluidLoadable>> }
	>,
): SharedObjectRegistry {
	return async () => {
		const map = new Map<string, SharedObjectKindAlpha<IFluidLoadable>>();
		for (const entry of entries) {
			if ("kind" in entry) {
				map.set(entry.type, await entry.kind());
			} else {
				map.set(asSharedObjectKind(entry).getFactory().type, entry);
			}
		}
		return (type: string) => {
			const entry = map.get(type);
			if (entry === undefined) {
				throw new UsageError(`Unknown shared object type: ${type}`);
			}
			return entry;
		};
	};
}
export interface DataStoreOptions<in out TRoot extends IFluidLoadable, out TOutput> {
	readonly type: string;
	readonly registry: SharedObjectRegistry;
	instantiateFirstTime(
		rootCreator: SharedObjectCreator<TRoot>,
		context: DataStoreContext,
	): Promise<TRoot>;
	view(root: TRoot, context: DataStoreContext): Promise<TOutput>;
}
export function defineDataStore<T, TRoot extends IFluidLoadable>(
	options: DataStoreOptions<TRoot, T>,
): DataStoreKind<T> {
	return new DataStoreKindImplementation<T>({
		type: options.type,
		async instantiateDataStore(
			context: IFluidDataStoreContext,
			existing: boolean,
		): Promise<IFluidDataStoreChannel> {
			return createDataStore(context, existing, options);
		},
	});
}
function asSharedObjectKind<T extends IFluidLoadable>(
	kind: SharedObjectKindAlpha<T>,
): ISharedObjectKind<T> {
	const candidate = kind as unknown as Partial<ISharedObjectKind<T>>;
	if (typeof candidate.getFactory !== "function" || typeof candidate.create !== "function") {
		throw new UsageError(
			"Invalid SharedObjectKindAlpha: this type is sealed and may not have custom implementations.",
		);
	}
	return candidate as ISharedObjectKind<T>;
}
function convertRegistry(
	lookup: Registry<SharedObjectKindAlpha<IFluidLoadable>>,
): ISharedObjectRegistry {
	return {
		get: (type: string) => {
			const entry = lookup(type);
			return asSharedObjectKind(entry).getFactory();
		},
	};
}
const rootSharedObjectId = "root";
async function createDataStore<T, TRoot extends IFluidLoadable>(
	context: IFluidDataStoreContext,
	existing: boolean,
	options: DataStoreOptions<TRoot, T>,
): Promise<IFluidDataStoreChannel> {
	const sharedObjectRegistry = await options.registry();
	const runtime: FluidDataStoreRuntime = new FluidDataStoreRuntime(
		context,
		convertRegistry(sharedObjectRegistry),
		existing,
		async (runtimeInner: IFluidDataStoreRuntime) => {
			const innerContext: DataStoreContext = {
				async createSharedObject<T2 extends IFluidLoadable>(
					key: SharedObjectKey<T2>,
				): Promise<T2> {
					const kind = lookupInRegistry(sharedObjectRegistry, key);
					return asSharedObjectKind(kind).create(runtimeInner);
				},
			};
			let createdRoot: TRoot | undefined;
			const rootCreator: SharedObjectCreator<TRoot> = {
				async createSharedObject<T2 extends TRoot>(key: SharedObjectKey<T2>): Promise<T2> {
					if (createdRoot !== undefined) {
						throw new UsageError("Root shared object already created");
					}
					const kind = lookupInRegistry(sharedObjectRegistry, key);
					const result = asSharedObjectKind(kind).create(runtimeInner, rootSharedObjectId);
					const rootSharedObject = result as IFluidLoadable as ISharedObject;
					rootSharedObject.bindToContext();
					createdRoot = result;
					return result;
				},
			};
			let root: TRoot | undefined;
			if (existing) {
				root = (await runtimeInner.getChannel(rootSharedObjectId)) as IFluidLoadable as TRoot;
			} else {
				root = await options.instantiateFirstTime(rootCreator, innerContext);
				if (root !== createdRoot) {
					throw new UsageError(
						"instantiateFirstTime did not return root created with rootCreator",
					);
				}
			}
			return (await options.view(root, innerContext)) as unknown as FluidObject;
		},
	);
	return runtime;
}
export interface SharedObjectCreator<TConstraint = IFluidLoadable> {
	createSharedObject<T extends TConstraint>(kind: SharedObjectKey<T>): Promise<T>;
}
export interface DataStoreContext extends SharedObjectCreator {}
```



## 5. Invariants and asserts

Assertions below terminate the current operation; do not convert them into successful no-ops. Ordered contracts above retain the exact condition at each failure site.

- `0xb8c`: bind must be an ISharedObjectHandle. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:88`
- `0xb8d`: bind must be an ISharedObjectHandle. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:121`
- `0xa93`: Cannot encode a handle without a bind context. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:139`
- `0xc85`: bind must be an ISharedObjectHandle. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/utils.ts:99`
- `0x304`: Id cannot contain slashes. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:169`
- `0x349`: this.mc and/or this.logger has not been set. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:211`
- `0x07a`: "Services should be there to attach delta handler". `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:553`
- `0x075`: "SummarySerializer should be used for serializing data during summary.". `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:766`
- `0x078`: "Possible re-entrancy! Summary should not already be in progress.". `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:838`
- `0x079`: "Possible re-entrancy! Summary should have been in progress.". `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:851`
- `0x97e`: received context must have a get function. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:897`
- `0xcee`: minVersionForCollab must be defined. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObjectKernel.ts:148`
- `0xb99`: initializeData must be called first and only once. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObjectKernel.ts:186`
- `0xcb0`: must initializeData first. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObjectKernel.ts:195`
- `0xb9a`: colliding properties. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObjectKernel.ts:348`
- `0xb9b`: methods returning thisWrap should return this. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObjectKernel.ts:391`

## 6. JS-semantics hazards

Maintain object identity on unchanged serializer subtrees; preserve handle-symbol recognition rather than structural duck typing. JSON replacer visits parent before descendants whereas JSON reviver visits children first. Undefined input stays undefined through serializeHandles; null stays null. bindHandles uses an explicit LIFO stack and visited Set (unlike serializer recursion, it can visit cyclic input safely). Listener re-entry is synchronous; throwing is state corruption, not a recoverable logging event. UTF-8 byte size is not Swift String.count. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:69-231` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/utils.ts:33-134` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:254-284`

## 7. Test assets to reuse

- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/attachingBindingAndConnecting.spec.ts:1-538` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/createSharedObjectKind.spec.ts:1-237` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/handle.spec.ts:1-88` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/serializer.perf.spec.ts:1-106` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/serializer.spec.ts:1-391` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/sharedObject.spec.ts:1-325` — reuse the oracle cases and expected values under the same operation order.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/sharedObjectDispatch.spec.ts:1-364` — reuse the oracle cases and expected values under the same operation order.

## 8. Open questions

None. The ordered contracts include the source behavior even where it is surprising; they are not a redesign.
