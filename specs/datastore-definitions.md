# datastore-definitions — native Swift port contract (3.11.0)

## 1. Role

Declares the DDS/channel boundary and the datastore service surface used by SharedObject and FluidDataStoreRuntime. This package does not implement scheduling, persistence or message transport. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:39-46` `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/dataStoreRuntime.ts:1-40`

## 2. Surface used by other packages

Port `IChannel`, `IChannelFactory`, `IChannelAttributes`, `IDeltaHandler`, `IDeltaConnection`, `IChannelStorageService`, `IChannelServices`, `IFluidDataStoreRuntime`, its event types and internal feature configuration. Serializable/Jsonable constrain allowed data but do not validate runtime values. The declarations below preserve field types, readonly/optional distinctions and all method argument order. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:39-339` `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/serializable.ts:7-28`

### storage: exact contract

`reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/storage.ts:1-26`. Normative TypeScript notation; declaration optionality, guards, defaults, statement order and failure branches are literal. Only imports and comments are removed.

```typescript
export interface IChannelAttributes {
	readonly type: string;
	readonly snapshotFormatVersion: string;
	readonly packageVersion?: string;
}
```

### channel: exact contract

`reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:1-339`. Normative TypeScript notation; declaration optionality, guards, defaults, statement order and failure branches are literal. Only imports and comments are removed.

```typescript
export interface IChannel extends IFluidLoadable {
	readonly id: string;
	readonly attributes: IChannelAttributes;
	getAttachSummary(
		fullTree?: boolean,
		trackState?: boolean,
		telemetryContext?: ITelemetryContext,
	): ISummaryTreeWithStats;
	summarize(
		fullTree?: boolean,
		trackState?: boolean,
		telemetryContext?: ITelemetryContext,
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext,
	): Promise<ISummaryTreeWithStats>;
	isAttached(): boolean;
	connect(services: IChannelServices): void;
	getGCData(fullGC?: boolean): IGarbageCollectionData;
}
export interface IDeltaHandler {
	processMessages: (messageCollection: IRuntimeMessageCollection) => void;
	setConnectionState(connected: boolean): void;
	reSubmit(message: any, localOpMetadata: unknown, squash?: boolean): void;
	applyStashedOp(message: any): void;
	rollback?(message: any, localOpMetadata: unknown): void;
}
export interface IDeltaConnection {
	connected: boolean;
	submit(messageContent: any, localOpMetadata: unknown): void;
	attach(handler: IDeltaHandler): void;
	dirty(): void;
}
export interface IChannelStorageService {
	readBlob(path: string): Promise<ArrayBufferLike>;
	contains(path: string): Promise<boolean>;
	list(path: string): Promise<string[]>;
	getSnapshotTree(): ISnapshotTree | undefined;
}
export interface IChannelServices {
	deltaConnection: IDeltaConnection;
	objectStorage: IChannelStorageService;
}
export interface IChannelFactory<out TChannel = unknown> {
	readonly type: string;
	readonly attributes: IChannelAttributes;
	load(
		runtime: IFluidDataStoreRuntime,
		id: string,
		services: IChannelServices,
		channelAttributes: Readonly<IChannelAttributes>,
	): Promise<TChannel & IChannel>;
	create(runtime: IFluidDataStoreRuntime, id: string): TChannel & IChannel;
}
```

### dataStoreRuntime: exact contract

`reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/dataStoreRuntime.ts:1-249`. Normative TypeScript notation; declaration optionality, guards, defaults, statement order and failure branches are literal. Only imports and comments are removed.

```typescript
export interface IFluidDataStoreRuntimeEvents extends IEvent {
	(event: "disconnected", listener: () => void);
	(event: "dispose", listener: () => void);
	(event: "attaching", listener: () => void);
	(event: "attached", listener: () => void);
	(event: "op", listener: (message: ISequencedDocumentMessage) => void);
	(event: "signal", listener: (message: IInboundSignalMessage, local: boolean) => void);
	(event: "connected", listener: (clientId: string) => void);
	(event: "readonly", listener: (isReadOnly: boolean) => void);
}
export type IDeltaManagerErased =
	ErasedType<"@fluidframework/container-definitions.IDeltaManager<ISequencedDocumentMessage, IDocumentMessage>">;
export interface IFluidDataStoreRuntime
	extends IEventProvider<IFluidDataStoreRuntimeEvents>,
		IDisposable {
	readonly id: string;
	readonly IFluidHandleContext: IFluidHandleContext;
	readonly rootRoutingContext: IFluidHandleContext;
	readonly channelsRoutingContext: IFluidHandleContext;
	readonly objectsRoutingContext: IFluidHandleContext;
	readonly options: Record<string | number, any>;
	readonly deltaManager: IDeltaManagerErased;
	readonly clientId: string | undefined;
	readonly connected: boolean;
	readonly isReadOnly: () => boolean;
	readonly logger: ITelemetryBaseLogger;
	readonly attachState: AttachState;
	readonly idCompressor: IIdCompressor | undefined;
	getChannel(id: string): Promise<IChannel>;
	createChannel(id: string | undefined, type: string): IChannel;
	addChannel(channel: IChannel): void;
	bindChannel(channel: IChannel): void;
	uploadBlob(
		blob: ArrayBufferLike,
		signal?: AbortSignal,
	): Promise<IFluidHandle<ArrayBufferLike>>;
	submitSignal: (type: string, content: unknown, targetClientId?: string) => void;
	getQuorum(): IQuorumClients;
	getAudience(): IAudience;
	waitAttached(): Promise<void>;
	readonly entryPoint: IFluidHandle<FluidObject>;
	readonly activeLocalOperationActivity?: "applyStashed" | "rollback" | undefined;
	readonly inStagingMode: boolean;
	readonly isDirty: boolean;
}
export interface IFluidDataStoreRuntimeAlpha extends IFluidDataStoreRuntime {}
export interface IFluidDataStoreRuntimeInternalConfig {
	readonly submitMessagesWithoutEncodingHandles?: boolean;
	readonly minVersionForCollab?: OldestSupportedClientVersion;
	readonly oldestSupportedClient?: OldestSupportedClientVersion;
}
```

### jsonable: exact contract

`reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/jsonable.ts:1-113`. Normative TypeScript notation; declaration optionality, guards, defaults, statement order and failure branches are literal. Only imports and comments are removed.

```typescript
export type JsonableTypeWith<T> =
	| undefined
	| null
	| boolean
	| number
	| string
	| T
	| Internal_InterfaceOfJsonableTypesWith<T>
	| ArrayLike<JsonableTypeWith<T>>;
export interface Internal_InterfaceOfJsonableTypesWith<T> {
	[index: string | number]: JsonableTypeWith<T>;
}
export type Jsonable<T, TReplaced = never> =  boolean extends (
	T extends never
		? true
		: false
)
	?  JsonableTypeWith<TReplaced>
	:  unknown extends T
		?  JsonableTypeWith<TReplaced>
		:  T extends
					| undefined
					| null
					| boolean
					| number
					| string
					| TReplaced
			?  T
			:
				 Extract<T, Function> extends never
				?  T extends object
					?  T extends (infer U)[]
						?  Jsonable<U, TReplaced>[]
						:  {
								[K in keyof T]: Extract<K, symbol> extends never
									? Jsonable<T[K], TReplaced>
									: never;
							}
					:  never
				:  never;
```

### serializable: exact contract

`reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/serializable.ts:1-28`. Normative TypeScript notation; declaration optionality, guards, defaults, statement order and failure branches are literal. Only imports and comments are removed.

```typescript
export type Serializable<T> = Jsonable<T, IFluidHandle>;
```

## 3. Wire and persisted formats

### Attributes and service-owned values

`.attributes` stores JSON of channel attributes: required `type:string`, required `snapshotFormatVersion:string`, optional `packageVersion:string`. Example attribute object created in declaration order: `{"type":"example.dds","snapshotFormatVersion":"1","packageVersion":"3.11.0"}`. The interface itself does not define property emission order; the wrapper stringifies the actual producer object in its existing JS key order. Older missing snapshotFormatVersion is tolerated operationally because load only compares versions when defined. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/storage.ts:10-26` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:124-147` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:193-213`

`IChannelServices={deltaConnection:IDeltaConnection,objectStorage:IChannelStorageService}` is an in-memory pair, never a wire payload. Local metadata is arbitrary `unknown`, may be undefined on local ops and always is undefined on remote ops; it is passed separately to submit, acknowledgment, reSubmit and rollback. `getSnapshotTree()` may return undefined. No wire version tag is added by these interfaces. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:154-339`

Serializable<T> is Jsonable<T,IFluidHandle>. JSON-capable values include undefined, null, boolean, number, string, object bags and arrays plus handle leaves. No cycles check is implied by the type. No separate encoded format is produced here. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/serializable.ts:7-28` `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/jsonable.ts:24-113`

## 4. Behavior

### Required lifecycle contract

Factory create is synchronous and returns local unbound channel; factory load is asynchronous and receives runtime, id, services and attributes, in that order. Channel connect enables delta processing. Attach summary is synchronous, has no prior summary handles, but may contain uploaded blob attachments. Ordinary summarize is async; callers must not allow modifications during it. Both return tree+stats and take fullTree/trackState/telemetry in that order, with incremental context added only to ordinary summarize. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:39-151` `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:294-339`

`IDeltaHandler.processMessages` accepts a collection; setConnectionState is synchronous; reSubmit may submit zero, one or several messages, and `squash` requests suppression of intermediate state superseded by later pending edits. applyStashedOp applies as a local edit including submitting if attached, returning void; rollback is optional. Delta connection attach registers the handler once; dirty requests summary inclusion without an op. These are contracts, not extra emitted events or transport frames. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:154-277`

The runtime event declarations in section 2 provide the exact listener argument tuples. The actual event-emitting sequence is implemented by datastore, not by this declarations package. Its consumer's receive path is: decrement own pending count, process routed DDS collection/attachment, then emit runtime op for each original content. `reference/fluidframework-3.11.0/packages/runtime/datastore/src/dataStoreRuntime.ts:1013-1049`

Handle conversion, summary wrapper and connection-state implementations are included here as complete operational boundary algorithms rather than leaving interface behavior implicit.


### Definition versus implementation defaults

Channel getAttachSummary/summarize document default fullTree=false and trackState=false; factory signatures do not add defaults themselves. IDeltaHandler.applyStashedOp returns void and must reapply edits through the local-edit path, while datastore runtime applyStashedOp returns a Promise of the capture metadata reconstructed by its delta connection. These are different layer signatures, not competing definitions. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:49-128` `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/channel.ts:154-196` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:137-154`

The type of snapshotFormatVersion is required string, but older attribute blobs can omit it at runtime. Factories receive the original parsed attributes rather than having current defaults overwrite them; comparison is diagnostic, not migration. A completely missing attributes blob requires an attach-provided type so factory attributes can be used. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/storage.ts:10-26` `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelContext.ts:150-213`

### channelDeltaConnection: exact contract

`reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:1-154`. Normative TypeScript notation; declaration optionality, guards, defaults, statement order and failure branches are literal. Only imports and comments are removed.

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

## 5. Invariants and asserts

- `0x177`: "Missing delta handler". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:77`
- `0x178`: "Missing delta handler on attach". `reference/fluidframework-3.11.0/packages/runtime/datastore/src/channelDeltaConnection.ts:92`

## 6. JS-semantics hazards

Preserve undefined vs null: optional properties do not mean nullable, and `unknown` metadata is not equivalent to an optional JSON value. `JSON.stringify` drops undefined object properties and gives null for undefined array elements/nonfinite numbers; root undefined produces undefined, not the string "null" (the Jsonable documentation's root-undefined phrasing is not the JS runtime behavior). These type constraints neither sanitize nor serialize data. Symbol keys, prototypes and non-enumerable properties are not ordinary persisted data; synchronous callback contracts must not become actor hops. `reference/fluidframework-3.11.0/packages/runtime/datastore-definitions/src/jsonable.ts:62-113` `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/utils.ts:33-39`

## 7. Test assets to reuse

- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/attachingBindingAndConnecting.spec.ts:1-538` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/createSharedObjectKind.spec.ts:1-237` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/handle.spec.ts:1-88` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/serializer.perf.spec.ts:1-106` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/serializer.spec.ts:1-391` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/sharedObject.spec.ts:1-325` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/test/sharedObjectDispatch.spec.ts:1-364` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/channelStorageService.spec.ts:1-83` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/dataStoreLayerCompatValidation.spec.ts:1-294` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/dataStoreRuntime.spec.ts:1-678` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/localChannelContext.spec.ts:1-149` — reuse expected outputs and callback ordering as oracle cases.
- `reference/fluidframework-3.11.0/packages/runtime/datastore/src/test/remoteChannelContext.spec.ts:1-234` — reuse expected outputs and callback ordering as oracle cases.

## 8. Open questions

None.
