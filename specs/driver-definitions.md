# driver-definitions — 3.11.0

## 1. Role

Driver-neutral contracts linking the loader to storage, delta storage and ordering-service connections; protocol, summary, Git REST and error data shapes. This package is predominantly declarations, not a networking stack. The Swift data-model port already retains received JSON objects and unknown fields in `DriverJSONValue`; native service protocols must be added without replacing that ordered backing representation. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:147-214`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:372-448`, `Sources/FluidDriverDefinitions/JSONModel.swift:3-38`)

## 2. Surface used by other packages

### Resolver and factory

`IUrlResolver.resolve(request:IRequest):Promise<IResolvedUrl|undefined>` resolves Fluid destinations; undefined means unsupported/unresolved, not an empty URL. `getAbsoluteUrl(resolvedUrl,relativeUrl,packageInfoSource?:{name:string}):Promise<string>` generates an external URL using optional container package name. Resolved URL fields are required: type literal `fluid`, id:string, url:string, tokens:{[name:string]:string}, endpoints:{[name:string]:string}; these maps are driver-specific and must not be hardcoded to one provider. DriverPreCheckInfo has optional codeDetailsHint:string and criticalBootDomains:string[]. Headers are literal `fluid-client-summarizer`:boolean and `createNew`:any, both optional through IRequestHeader augmentation. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/urlResolver.ts:11-102`)

Factory createDocumentService(resolvedUrl,logger?,clientIsSummarizer?):Promise<IDocumentService> loads an existing file. createContainer(createNewSummary:ISummaryTree|undefined,createNewResolvedUrl,logger?,clientIsSummarizer?):Promise<IDocumentService> creates one. Summarizer undefined means false. An undefined create summary creates an empty file which must receive a summary **before ordering-service connection**. Neither method returns a delta connection or implicitly promises it is connected. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:413-448`)

### IDocumentService

Required resolvedUrl; optional policies; connectToStorage():Promise<IDocumentStorageService>; connectToDeltaStorage():Promise<IDocumentDeltaStorageService>; connectToDeltaStream(client:IClient):Promise<IDocumentDeltaConnection>; dispose(error?:any):void. Event `metadataUpdate(metadata:Record<string,string>)`. Policies all optional booleans: storageOnly forbids delta-stream connection, summarizeProtocolTree requests protocol-tree upload with summaries, supportGetSnapshotApi advertises complete support for bundled snapshot fetch. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:220-226`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:350-408`)

Disposal lets storage flush pending state/local caching. Critical error disposal must invalidate affected local caches. **It does not close active delta connections**: caller owns and closes those separately. No assumption that dispose means remote deletion. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:395-407`)

### IDocumentStorageService

- readonly policies?:{caching?:LoaderCachingPolicy,maximumCacheDurationMs?:432000000}; NoCaching=0, Prefetch=1. Maximum duration is exactly five days, not an arbitrary numeric duration; absent means no age guarantee. GC-enabled usage requires the five-day guarantee actually enforced for latest snapshots, not merely advertised. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:112-141`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:335-345`)
- getSnapshotTree(version?:IVersion,scenarioName?:string):Promise<ISnapshotTree|null>. Null is valid no-snapshot result. Optional getSnapshot(options?:ISnapshotFetchOptions):Promise<ISnapshot> returns tree plus bytes and ops. Options: scenarioName?:string, cacheSnapshot?:boolean, versionId?:string, loadingGroupIds?:string[], fetchSource?:FetchSource. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:147-169`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:505-535`)
- getVersions(versionId:string|null,count:number,scenarioName?:string,fetchSource?:FetchSource):Promise<IVersion[]>; null starts at head. FetchSource.default=`default`, noCache=`noCache`; noCache bypasses stale cache for current information. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:171-189`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:472-475`)
- createBlob(file:ArrayBufferLike):Promise<{id:string}>; readBlob(id:string):Promise<ArrayBufferLike>. Raw bytes are not a base64 string at this interface. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:191-199`)
- uploadSummaryWithContext(summary:ISummaryTree,context:ISummaryContext):Promise<string>. Context required fields proposalHandle:string|undefined, ackHandle:string|undefined, referenceSequenceNumber:number; handles in tree address objects in previously acknowledged summary. downloadSummary(handle:ISummaryHandle):Promise<ISummaryTree> may reject if a packfile was already committed/deleted. Optional IDisposable members are permitted, not required. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:201-214`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:455-467`)

ISnapshot fields: snapshotTree:ISnapshotTree; blobContents:Map<string,ArrayBuffer>; ops:ISequencedDocumentMessage[]; sequenceNumber:number|undefined (snapshot reference); latestSequenceNumber:number|undefined (latest known op); snapshotFormatV literal 1. These two sequence fields are present at the type level but may be undefined; JSON encoding omits them then. A Map serializes as `{}`, **not** its entries; native persistence must use the driver's actual bytes/container representation, not naïve JSON.stringify(ISnapshot). (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:482-498`, `Sources/FluidDriverDefinitions/StructuredValues.swift:95-110`)

### Delta storage

IDocumentDeltaStorageService.fetchMessages(from:number,to:number|undefined,abortSignal?,cachedOnly?,fetchReason?):IStream<ISequencedDocumentMessage[]> returns the stream **synchronously**, not a promise of stream. Range is **[from,to)** despite conflicting prose saying exclusive range. Undefined to is open-ended; cachedOnly limits to available local ops. Each async read returns either `{done:false,value:messages}` or `{done:true}`; no value is required on done. Read until done, not until a short/empty chunk. Lower-level IDeltaStorageService.get(tenantId,id,from,to,fetchReason?):Promise<{messages,partialResult}> uses same endpoints; partialResult true means more ops remain in requested range, false means fulfilled or no more available. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:36-110`)

### IDocumentDeltaConnection

Required mutable/readable fields clientId:string, claims:ITokenClaims, mode:`read|write`, existing:boolean, version:string, initialMessages:sequenced[], initialSignals:signal[], initialClients:ISignalClient[], serviceConfiguration:IClientConfiguration; optional checkpointSequenceNumber:number and relayServiceAgent:string (diagnostic `prop1:val1;prop2:val2` string). Checkpoint can lag actual service head. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:253-316`)

submit(messages:IDocumentMessage[]):void; submitSignal(content:string,targetClientId?:string):void; IDisposable disposal. Events, exact argument order: nack(documentId:string,messages:INack[]); disconnect(reason:IAnyDriverError); op(documentId:string,messages:ISequencedDocumentMessage[]); signal(message:ISignalMessage|ISignalMessage[]); pong(latency:number); error(error:any). 3.11.0 disconnect signature requires an error; source explicitly announces a **future**, not current, undefined clean-disconnect argument. Defensive native reception may preserve absence without claiming it was this version's declared contract. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:231-248`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:318-330`)

### Full driver error taxonomy

Base fields: errorType:DriverErrorTypes, message:string, mutable canRetry:boolean, optional online:string and endpointReached:boolean. IAnyDriverError widens errorType to arbitrary string (driver extensions) and adds scenarioName?:string, usually the socket event (`connect_error`, `connect_document_error`). Driver errors need not be JS Error instances and do not require stack/name. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/driverError.ts:114-167`)

Inherited categories, in order: genericError, throttlingError, usageError, layerIncompatibilityError. The driver explicitly removes dataCorruptionError and dataProcessingError from FluidErrorTypes before spreading; do not add them back to a closed native driver enum. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/driverError.ts:11-20`, `reference/fluidframework-3.11.0/packages/common/core-interfaces/src/error.ts:12-49`)

Added keys equal literal string values:

| errorType | Meaning |
|---|---|
| genericNetworkError | uncategorized network/server failure, including fatal 500 |
| authorizationError | insufficient privileges to open/continue |
| fileNotFoundOrAccessDeniedError | absent/deleted or denied file |
| offlineError | detected offline/unreachable server |
| unsupportedClientProtocolVersion | unsupported client protocol |
| writeError | edits attempted without write permission |
| fetchFailure | no server response, e.g. DNS/CSP/malformed request; offlineError preferred when offline detected |
| fetchTokenError | orderer token provider failed |
| incorrectServerResponse | malformed JSON or required properties absent |
| fileOverwrittenInStorage | file identity/content replaced externally; forget stale file knowledge |
| deltaStreamConnectionForbidden | readonly document forbids streaming |
| locationRedirection | file moved; new resolved location supplied |
| fluidInvalidSchema | non-Fluid content bearing Fluid extension |
| fileIsLocked | storage read/write lock |
| outOfStorageError | storage full |

This table is in declaration/spread insertion order, not a retry-priority order. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/driverError.ts:18-107`)

Specialized variants: IThrottlingWarning fixes throttlingError and requires retryAfterSeconds:number; IGenericNetworkError adds statusCode?:number; IAuthorizationError adds claims?:string,tenantId?:string; ILocationRedirectionError requires redirectUrl:IResolvedUrl. IDriverBasicError permits genericError, fileNotFoundOrAccessDeniedError, offlineError, unsupportedClientProtocolVersion, writeError, fetchFailure, fetchTokenError, incorrectServerResponse, fileOverwrittenInStorage, fluidInvalidSchema, usageError, fileIsLocked, outOfStorageError, with statusCode?:number. DriverError is union of these five interfaces. **deltaStreamConnectionForbidden and layerIncompatibilityError exist in constants but are not members of that closed union**; IAnyDriverError is the broad transport boundary. Retry is determined by canRetry, not inferred from category or HTTP status. Loader helper allows retry only for a non-null object whose canRetry is exactly true (not truthiness); missing/false/unexpected exceptions are fatal. getRetryDelaySecondsFromError accepts only typeof number, without finite/nonnegative validation, and getRetryDelayFromError multiplies that by 1000. (`reference/fluidframework-3.11.0/packages/loader/driver-utils/src/network.ts:253-281`) Seconds must be converted only where a caller expects milliseconds. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/driverError.ts:172-233`)

## 3. Wire and persisted formats

Interfaces do not emit properties: declaration order is not a serializer. Preserve received unknown properties and property order; authored order belongs to a concrete producer. Exact protocol schemas are transcribed below with optionality and discriminants. `?` means optional/missing; `|undefined` is required in-memory but may disappear in JSON. Unknown payloads are not coerced to strings. All numbers are JS number; native sequence counters validate integral safe range. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:141-300`, `Sources/FluidDriverDefinitions/JSONModel.swift:3-38`)

Summary variants: tree `{type:1,tree:Record<string,SummaryObject>,unreferenced?:true,groupId?:string}`; blob `{type:2,content:string|Uint8Array}`; handle `{type:3,handleType:1|2|4,handle:string}`; attachment `{type:4,id:string}`. Handle paths refer to prior summary, not Fluid object handles. `unreferenced` is true-or-absent, never a required false flag. Snapshot trees instead use blobs map path->blobID and child trees, no numeric summary discriminator. Binary blob is an in-memory byte view; JSON.stringify(Uint8Array([1,255])) produces `{"0":1,"1":255}`, not `[1,255]` and not base64. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/summary.ts:91-189`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/storage.ts:133-158`)

Concrete single-blob summary (type then tree, child type then content) is `{"type":1,"tree":{"header":{"type":2,"content":"{}"}}}`. SummaryTreeBuilder emits the parent as type,tree and addBlob uses type,content; this is a producer example, not a generic driver serialization rule. (`reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:142-157`, `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:192-202`)

ConnectionManager-generated initial clear signal: outer insertion order clientId then content; value `{"clientId":null,"content":"{\"type\":\"clear\"}"}`. Each initial client becomes `{"clientId":null,"content":"{\"type\":\"join\",\"content\":<ISignalClient JSON>}"}`; the inner content is **a JSON string**, with type before content. clear is loader's extended signal type, not a missing exported protocol SignalType member. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:944-980`)

No package-wide protocol version negotiation algorithm is implemented here: IConnect.versions is an ordered string array and IConnected.version is the selected string; do not substitute package version 3.11.0 as a wire protocol version. Summary numeric kinds 1–4 and bundled snapshotFormatV=1 are distinct discriminants. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/sockets.ts:15-178`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:497`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/summary.ts:26-81`)

### Literal declaration inventory

The following source-derived declarations give all protocol/storage/cache/Git field names, types, optionality and numeric/string tags. Methods are in-process service contracts, not JSON keys. Imported symbols refer to the literal declarations in this inventory; inheritance includes all parent fields. Interface members impose no emission order. No fields are elided.

#### protocol/clients.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/clients.ts:6-152`)

```ts
export type ConnectionMode = "write" | "read";
export interface ICapabilities {
	interactive: boolean;
}
export interface IClientDetails {
	capabilities: ICapabilities;
	type?: string;
	environment?: string;
	device?: string;
}
export interface IClient {
	mode: ConnectionMode;
	details: IClientDetails;
	permission: string[];
	user: IUser;
	scopes: string[];
	timestamp?: number;
}
export interface ISequencedClient {
	client: IClient;
	sequenceNumber: number;
}
export interface ISignalClient {
	clientId: string;
	client: IClient;
	clientConnectionNumber?: number;
	referenceSequenceNumber?: number;
}
export interface IClientJoin {
	clientId: string;
	detail: IClient;
}
```

#### protocol/config.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/config.ts:6-38`)

```ts
export interface IClientConfiguration {
	maxMessageSize: number;
	blockSize: number;
	noopTimeFrequency?: number;
	noopCountFrequency?: number;
}
```

#### protocol/tokens.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/tokens.ts:6-68`)

```ts
export interface ITokenClaims {
	documentId: string;
	scopes: string[];
	tenantId: string;
	user: IUser;
	iat: number;
	exp: number;
	ver: string;
	jti?: string;
}
```

#### protocol/users.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/users.ts:6-15`)

```ts
export interface IUser {
	id: string;
}
```

#### protocol/protocol.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:6-554`)

```ts
export enum MessageType {
	NoOp = "noop",
	ClientJoin = "join",
	ClientLeave = "leave",
	Propose = "propose",
	Reject = "reject",
	Accept = "accept",
	Summarize = "summarize",
	SummaryAck = "summaryAck",
	SummaryNack = "summaryNack",
	Operation = "op",
	NoClient = "noClient",
	RoundTrip = "tripComplete",
	Control = "control",
}
export enum SignalType {
	ClientJoin = "join",
	ClientLeave = "leave",
}
export interface ITrace {
	service: string;
	action: string;
	timestamp: number;
}
export interface INack {
	operation: IDocumentMessage | undefined;
	sequenceNumber: number;
	content: INackContent;
}
export interface IDocumentMessage {
	clientSequenceNumber: number;
	referenceSequenceNumber: number;
	type: string;
	contents: unknown;
	metadata?: unknown;
	serverMetadata?: unknown;
	traces?: ITrace[];
	compression?: string;
}
export interface IDocumentSystemMessage extends IDocumentMessage {
	data: string;
}
export interface IBranchOrigin {
	id: string;
	sequenceNumber: number;
	minimumSequenceNumber: number;
}
export interface ISequencedDocumentMessage {
	clientId: string | null;
	sequenceNumber: number;
	minimumSequenceNumber: number;
	clientSequenceNumber: number;
	referenceSequenceNumber: number;
	type: string;
	contents: unknown;
	metadata?: unknown;
	serverMetadata?: unknown;
	origin?: IBranchOrigin;
	traces?: ITrace[];
	timestamp: number;
	data?: string;
	expHash1?: string;
	compression?: string;
}
export type ISequencedDocumentMessageExperimental = Omit<
	ISequencedDocumentMessage,
	"expHash1" | "compression"
> & {
	expHash1?: string;
	compression?: string;
};
export interface ISequencedDocumentSystemMessage extends ISequencedDocumentMessage {
	data: string;
}
export interface ISequencedDocumentAugmentedMessage extends ISequencedDocumentMessage {
	additionalContent: string;
}
export interface ISignalMessageBase<TMessage extends TypedMessage = TypedMessage> {
	content: TMessage["content"];
	type?: TMessage["type"];
	clientConnectionNumber?: number;
	referenceSequenceNumber?: number;
	targetClientId?: string;
}
export interface ISignalMessage<TMessage extends TypedMessage = TypedMessage>
	extends ISignalMessageBase<TMessage> {
	clientId: string | null;
}
export type ISentSignalMessage<TMessage extends TypedMessage = TypedMessage> =
	ISignalMessageBase<TMessage>;
export interface IUploadedSummaryDetails {
	includesProtocolTree?: boolean;
}
export interface ISummaryContent {
	handle: string;
	message: string;
	parents: string[];
	head: string;
	details?: IUploadedSummaryDetails;
}
export interface IServerError {
	errorMessage: string;
}
export interface ISummaryProposal {
	summarySequenceNumber: number;
}
export interface ISummaryAck {
	handle: string;
	summaryProposal: ISummaryProposal;
}
export interface ISummaryNack {
	summaryProposal: ISummaryProposal;
	code?: number;
	message?: string;
	retryAfter?: number;
}
export interface INackContent {
	code: number;
	type: NackErrorType;
	message: string;
	retryAfter?: number;
}
export enum NackErrorType {
	ThrottlingError = "ThrottlingError",
	InvalidScopeError = "InvalidScopeError",
	BadRequestError = "BadRequestError",
	LimitExceededError = "LimitExceededError",
}
```

#### protocol/sockets.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/sockets.ts:6-178`)

```ts
export interface IConnect {
	tenantId: string;
	id: string;
	token: string | null;
	client: IClient;
	versions: string[];
	driverVersion?: string;
	mode: ConnectionMode;
	nonce?: string;
	epoch?: string;
	supportedFeatures?: Record<string, unknown>;
	relayUserAgent?: string;
}
export interface IConnected {
	claims: ITokenClaims;
	clientId: string;
	existing: boolean;
	maxMessageSize: number;
	initialMessages: ISequencedDocumentMessage[];
	initialSignals: ISignalMessage[];
	initialClients: ISignalClient[];
	version: string;
	supportedVersions: string[];
	serviceConfiguration: IClientConfiguration;
	mode: ConnectionMode;
	nonce?: string;
	checkpointSequenceNumber?: number;
	epoch?: string;
	supportedFeatures?: Record<string, unknown>;
	timestamp?: number;
	relayServiceAgent?: string;
}
```

#### protocol/storage.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/storage.ts:6-179`)

```ts
export interface IDocumentAttributes {
	sequenceNumber: number;
	minimumSequenceNumber: number;
}
export enum FileMode {
	File = "100644",
	Executable = "100755",
	Directory = "040000",
	Symlink = "120000",
}
export interface IBlob {
	contents: string;
	encoding: "utf-8" | "base64";
}
export interface IAttachment {
	id: string;
}
export interface ICreateBlobResponse {
	id: string;
}
export type ITreeEntry = {
	path: string;
	mode: FileMode;
} & (
	| {
			type: TreeEntry.Blob;
			value: IBlob;
	  }
	| {
			type: TreeEntry.Tree;
			value: ITree;
	  }
	| {
			type: TreeEntry.Attachment;
			value: IAttachment;
	  }
);
export enum TreeEntry {
	Blob = "Blob",
	Tree = "Tree",
	Attachment = "Attachment",
}
export interface ITree {
	entries: ITreeEntry[];
	id?: string;
	unreferenced?: true;
	groupId?: string;
}
export interface ISnapshotTree {
	id?: string;
	blobs: { [path: string]: string };
	trees: { [path: string]: ISnapshotTree };
	unreferenced?: true;
	groupId?: string;
}
export interface ISnapshotTreeEx extends ISnapshotTree {
	id: string;
	trees: { [path: string]: ISnapshotTreeEx };
}
export interface IVersion {
	id: string;
	treeId: string;
	date?: IsoDate;
}
```

#### protocol/summary.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/summary.ts:6-189`)

```ts
export type SummaryObject = ISummaryTree | ISummaryBlob | ISummaryHandle | ISummaryAttachment;
export type SummaryTree = ISummaryTree | ISummaryHandle;
export namespace SummaryType {
	export type Tree = 1;
	export type Blob = 2;
	export type Handle = 3;
	export type Attachment = 4;
	export const Tree: Tree = 1;
	export const Blob: Blob = 2;
	export const Handle: Handle = 3;
	export const Attachment: Attachment = 4;
}
export type SummaryType =
	| SummaryType.Attachment
	| SummaryType.Blob
	| SummaryType.Handle
	| SummaryType.Tree;
export type SummaryTypeNoHandle = SummaryType.Tree | SummaryType.Blob | SummaryType.Attachment;
export interface ISummaryHandle {
	type: SummaryType.Handle;
	handleType: SummaryTypeNoHandle;
	handle: string;
}
export interface ISummaryBlob {
	type: SummaryType.Blob;
	content: string | Uint8Array;
}
export interface ISummaryAttachment {
	type: SummaryType.Attachment;
	id: string;
}
export interface ISummaryTree {
	type: SummaryType.Tree;
	tree: { [path: string]: SummaryObject };
	unreferenced?: true;
	groupId?: string;
}
```

#### protocol/consensus.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/consensus.ts:6-117`)

```ts
export interface IProposal {
	key: string;
	value: unknown;
}
export type ISequencedProposal = { sequenceNumber: number } & IProposal;
export type IApprovedProposal = { approvalSequenceNumber: number } & ISequencedProposal;
export type ICommittedProposal = { commitSequenceNumber: number } & IApprovedProposal;
export interface IQuorumClients {
	getMembers(): Map<string, ISequencedClient>;
	getMember(clientId: string): ISequencedClient | undefined;
	on(event: "addMember", listener: (clientId: string, details: ISequencedClient) => void);
	on(event: "removeMember", listener: (clientId: string) => void);
	on(event: "error", listener: (message: any) => void);
	once: IQuorumClients["on"];
	off: IQuorumClients["on"];
}
export interface IQuorumProposals {
	propose(key: string, value: unknown): Promise<void>;
	has(key: string): boolean;
	get(key: string): unknown;
	on(event: "addProposal", listener: (proposal: ISequencedProposal) => void);
	on(
		event: "approveProposal",
		listener: (
			sequenceNumber: number,
			key: string,
			value: unknown,
			approvalSequenceNumber: number,
		) => void,
	);
	on(event: "error", listener: (message: any) => void): void;
	once: IQuorumProposals["on"];
	off: IQuorumProposals["on"];
}
export interface IQuorum
	extends Omit<IQuorumClients, "on" | "once" | "off">,
		Omit<IQuorumProposals, "on" | "once" | "off"> {
	on: IQuorumClients["on"] & IQuorumProposals["on"];
	once: IQuorum["on"];
	off: IQuorum["on"];
}
export interface IProtocolState {
	sequenceNumber: number;
	minimumSequenceNumber: number;
	members: [string, ISequencedClient][];
	proposals: [number, ISequencedProposal, string[]][];
	values: [string, ICommittedProposal][];
}
export interface IProcessMessageResult {
	immediateNoOp?: boolean;
}
```

#### protocol/scopes.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/scopes.ts:6-25`)

```ts
export enum ScopeType {
	DocRead = "doc:read",
	DocWrite = "doc:write",
	SummaryWrite = "summary:write",
}
```

#### git/resources.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/git/resources.ts:6-251`)

```ts
export interface IAuthor {
	name: string;
	email: string;
	date: string;
}
export interface ICommitter {
	name: string;
	email: string;
	date: string;
}
export interface ICommitHash {
	sha: string;
	url: string;
}
export interface ICreateCommitParams {
	message: string;
	tree: string;
	parents: string[];
	author: IAuthor;
}
export interface ICommit {
	sha: string;
	url: string;
	author: IAuthor;
	committer: ICommitter;
	message: string;
	tree: ICommitHash;
	parents: ICommitHash[];
}
export interface ICommitDetails {
	url: string;
	sha: string;
	commit: {
		url: string;
		author: IAuthor;
		committer: ICommitter;
		message: string;
		tree: ICommitHash;
	};
	parents: ICommitHash[];
}
export interface IBlob {
	content: string;
	encoding: string;
	url: string;
	sha: string;
	size: number;
}
export interface ICreateBlobParams {
	content: string;
	encoding: "utf-8" | "base64";
}
export interface ICreateBlobResponse {
	sha: string;
	url: string;
}
export interface IRef {
	ref: string;
	url: string;
	object: {
		type: string;
		sha: string;
		url: string;
	};
}
export interface ICreateRefParams {
	ref: string;
	sha: string;
}
export interface IPatchRefParams {
	sha: string;
	force: boolean;
}
export interface ICreateRepoParams {
	name: string;
}
export interface ICreateTreeEntry {
	path: string;
	mode: string;
	type: string;
	sha: string;
}
export interface ICreateTreeParams {
	base_tree?: string;
	tree: ICreateTreeEntry[];
}
export interface ITreeEntry {
	path: string;
	mode: string;
	type: string;
	size: number;
	sha: string;
	url: string;
}
export interface ITree {
	sha: string;
	url: string;
	tree: ITreeEntry[];
}
export interface ITagger {
	name: string;
	email: string;
	date: string;
}
export interface ICreateTagParams {
	tag: string;
	message: string;
	object: string;
	type: string;
	tagger: ITagger;
}
export interface ITag {
	tag: string;
	sha: string;
	url: string;
	message: string;
	tagger: ITagger;
	object: {
		type: string;
		sha: string;
		url: string;
	};
}
```

#### cacheDefinitions.ts

(`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/cacheDefinitions.ts:6-127`)

```ts
export interface IFileEntry {
	docId: string;
	resolvedUrl: IResolvedUrl;
	fileVersion?: string;
}
export interface IEntry {
	type: string;
	key: string;
}
export interface ICacheEntry extends IEntry {
	file: IFileEntry;
}
export interface IPersistedCache {
	get(entry: ICacheEntry): Promise<unknown>;
	put(entry: ICacheEntry, value: unknown): Promise<void>;
	removeEntries(file: IFileEntry): Promise<void>;
	removeEntry?(entry: ICacheEntry): Promise<void>;
	update?(
		entry: ICacheEntry,
		updater: (existing: unknown, set: (value: unknown) => void) => void,
	): Promise<boolean>;
}
```

## 4. Behavior

This declaration package has no reconnect loop or service implementation. The executable loader boundary consumes the contracts in this order:

1. Existing load calls factory.createDocumentService(resolvedUrl,subLogger,isSummarizer); after fulfillment subscribes metadataUpdate if driver supplies on. Attach calls createContainer(summary,resolvedUrl,subLogger,false) through runWithRetry; config Fluid.Container.DisableCloseOnAttachFailure=true forces maxRetries=0, otherwise the retry helper's default applies. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:1572-1607`)
2. Connection setup asserts no old connection (0x0e6) and new connection not disposed (0x28a), clears pendingConnection, stores new connection, computes readonly permission from missing `doc:write` scope. Mode mismatch logs telemetry; readonly permission with write mode asserts 0x0e8. Update readonly permissions; if disposed during callback, disconnect and return. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:838-882`)
3. Resume outbound; install listeners in order op,signal,nack,disconnect,error,pong. Sort initialMessages **in place** ascending sequenceNumber; compute checkpoint=max(providedCheckpoint,lastInitialSequence), preserving undefined if neither exists. Send initialMessages to incomingOpHandler (reason InitialOps on first connection, ReconnectOps subsequently). Then save connection details and call connectHandler; set firstConnection=false. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:884-942`)
4. Construct clear signal, then joins in initialClients array order, then append initialSignals in supplied order. Pass whole list to signalHandler, whose loader implementation pushes each onto inboundSignal in that order. This reconstructs audience rather than trusting prior disconnected membership. Initial signals and clients have no inherent server-defined relative order; the loader deliberately applies this local ordering. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:944-983`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:447-453`)
5. For storage recovery, lazily connectToDeltaStorage. If bounded request already covered during await, return without another fetch. Bounded cancellation threshold is to-1; unbounded threshold is lastObservedSeqNumber. A socket op reaching threshold aborts the storage fetch unless that op came from the fetch itself. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:685-735`)
6. submitSignal disconnected logs submitSignalDisconnected; connected forwards content and optional target unchanged. This does not provide reliable storage or replay for signals. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:1109-1115`)

Cache update contract (optional IPersistedCache.update) is a synchronous transaction callback between read and commit: set(value) schedules replacement, set(undefined) deletion, no set leaves unchanged; throw preserves old row. Return true only when requested change commits, false for no set/throw/storage error. Implementing this as independent get+put breaks cross-tab compare-and-set semantics. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/cacheDefinitions.ts:104-126`)

ServiceClient helpers actually implemented here: lookupInRegistry evaluates registry(key.type), then key.adapt(result); createBasicRegistryKey emits `{type,adapt:identity}`; featureVersion splits dots and returns `<major>.<minor>.0`, including prerelease inputs. No semver validation occurs in the implementation. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/serviceClient.ts:99-116`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/serviceClient.ts:161-169`)

## 5. Invariants and asserts

Five-day maximum-cache policy is a GC safety invariant, not a suggestion to increase TTL. Empty-create summary must be posted before ordering connection. Delta range endpoints must not be both inclusive. Summary handleType excludes Handle (3). Mandatory nullable clientId in sequenced messages/signals is not equivalent to an absent property. Driver canRetry=false is fatal to retry callers even if errorType is a familiar transient category. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:112-140`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:434-435`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:95-109`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/summary.ts:91-124`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:217-299`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/driverError.ts:152-155`)

## 6. JS-semantics hazards

Swift must preserve received objects rather than rebuilding known fields: rebuilding drops extension metadata and changes key order. ISnapshot's Map/buffers do not survive plain JSON roundtrip. Nullable required clientId must decode missing as failure but null as nil. Sequence counters must be exact safe integers; opaque numeric metadata/timestamps remain Double. InitialMessages sorting mutates driver's array; stable equal-sequence ordering follows JS stable sort. Errors are open structural objects through IAnyDriverError, not an exhaustive closed Swift enum. (`Sources/FluidDriverDefinitions/JSONModel.swift:3-38`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/storage.ts:482-498`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:217-299`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:897-899`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/driverError.ts:126-132`)

## 7. Test assets to reuse

Maximum cache-duration type test confirms the literal five-day policy; generated compatibility tests cover interface evolution but do not prove service behavior. Connection-manager tests are the useful oracle for sorted reconnect initial ops and driver event sequencing; loader audience tests cover initial membership. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/test/types/maximumCacheDurationPolicy.spec.ts:1-36`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/test/types/validateDriverDefinitionsPrevious.generated.ts:1-40`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/connectionManager.spec.ts:1-40`, `reference/fluidframework-3.11.0/packages/test/test-end-to-end-tests/src/test/audience.spec.ts:1-40`)

## 8. Open questions

None for the common contract. Provider-specific endpoint schemas and transport serialization are not universal formats of driver-definitions; no common endpoint names, socket protocol version string, or storage binary container is invented here.
