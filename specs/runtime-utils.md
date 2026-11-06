# runtime-utils — native Swift port contract (3.11.0)

## 1. Role

Common runtime mechanisms used by datastore and shared-object-base: handle identity/serialization/resolution, request and storage path traversal, summary conversion/statistics, GC graph aggregation, compatibility selection and factory initialization. Service-client adapters share the same factory and registry boundaries. None is a replacement transport or DDS implementation. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/index.ts:1-103`

## 2. Surface used by other packages

Handles: FluidHandleBase, RemoteFluidObjectHandle, isFluidHandle, internal/erased conversion, pending-payload predicates, compareFluidHandles, encodeHandleForSerialization, lookupTemporaryBlobStorageId and getDataStorePackagePath. Routing/storage: generateHandleContextPath, RequestParser, ObjectStoragePartition, getNormalizedObjectStoragePathParts, listBlobsAtTreePath and RuntimeHeaders. Summaries: SummaryTreeBuilder, conversion helpers, mergeStats/calculateStats/getBlobSize/utf8ByteLength, mutation helpers, GCDataBuilder, processAttachMessageGCData, TelemetryContext and unpackChildNodesUsedRoutes. Initialization/compatibility/service adapters and delta-manager casts are included in the ordered algorithms below; no port must reconstruct an implementation from a signature. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/index.ts:1-103`

## 3. Wire and persisted formats

### Handles and requests

Encoding emits `{"type":"__fluid_handle__","url":"/s/c"}` in type,url order; only an internal handle with payloadPending strictly true adds `,"payloadPending":true` last. No false/null placeholder. Recognizer checks only optional `.type` equality; it does not validate url or strip extra fields. This package emits absolute URLs; serializer backward-relative decoding lives in shared-object-base. The marker is not an ordinary object tag to reinterpret outside Fluid serialization. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:1-264`

Remote get constructs `{url:absolutePath,headers:{viaHandle:true,payloadPending:boolean}}` in that order, including payloadPending **false** when false (unlike encoded handle). Resolve success is determined solely by `mimeType === "fluid/object"`, not status code. The request and returned response are local service values, not a new network request protocol. RuntimeHeaders are the literal strings `wait`, `viaHandle`, `payloadPending`. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/remoteFluidObjectHandle.ts:1-70` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/utils.ts:1-109`

### Summary objects, ITree and GC

SummaryTreeBuilder emits `{type:1,tree:{...children},groupId?:string}`; groupId is inserted only when not undefined. Child blob is `{type:2,content:string|Uint8Array}`, handle is `{type:3,handleType:1|2|4,handle:string}`, attachment is `{id:string,type:4}`. Attachments receive decimal keys from a separate zero-based counter and no stats increment. Stats always contain, in order, treeNodeCount, blobNodeCount, handleNodeCount, totalBlobSize, unreferencedBlobSize. Fresh builder has `[1,0,0,0,0]`. Getter returns shallow copies of tree/stats, not deep immutable trees. `addBlob("header","x")` yields `{"summary":{"type":1,"tree":{"header":{"type":2,"content":"x"}}},"stats":{"treeNodeCount":1,"blobNodeCount":1,"handleNodeCount":0,"totalBlobSize":1,"unreferencedBlobSize":0}}`. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

`convertSummaryTreeToITree` emits `{entries:ITreeEntry[],unreferenced:boolean|undefined,groupId:string|undefined}` in that order; JSON drops undefined properties. Blob entry property order is path,mode,type,value; tree entry order is path,value,mode,type; attachment entry order is path,id,mode,type,value (the constructor exposes id both at top level and in value). These orders follow ES2022 field initialization with TS parameter-property declarations emitted before ordinary fields. Blob mode `"100644"`, type `"Blob"`, value `{contents:string,encoding:"utf-8"|"base64"}`; tree mode `"040000"`, type `"Tree"`, recursive ITree value; attachment mode `"100644"`, type `"Attachment"`, value `{id:string}`. Example header conversion: `{"entries":[{"path":"header","mode":"100644","type":"Blob","value":{"contents":"x","encoding":"utf-8"}}]}`. A binary byte FF becomes contents `"/w=="`, encoding `"base64"`. Do not change persisted spelling `utf-8` to `utf8`. A summary Handle cannot be converted to ITree. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631` `reference/fluidframework-3.11.0/packages/loader/driver-utils/src/blob.ts:13-73`

Legacy ITree with truthy id and !fullTree converts to `{summary:{handle:id,handleType:1,type:3},stats:{treeNodeCount:0,blobNodeCount:0,handleNodeCount:1,totalBlobSize:0,unreferencedBlobSize:0}}`. Otherwise recursively convert entries; a base64 blob becomes binary, any other encoding keeps string. Full trees copy unreferenced and groupId even when undefined. Detached ISnapshotTree conversion reads modern blobsContents[id] as UTF-8; if blobsContents is present but id missing, skip it, do not fall back. Only when blobsContents itself is absent, use legacy blobs[id] base64 content for each path->id mapping; skip unmatched mappings. Child trees follow blob traversal. Both old and new detached forms remain readable. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

Attach GC lives in first entry whose path is `.gcdata`, a `Blob` with encoding exactly `"utf-8"` and JSON body `{gcNodes:{[nodeId:string]:string[]}}`; example `{"gcNodes":{"/":["/s/c"]}}`. Old attach without snapshot or GC data returns false with no callback. GCDataBuilder getGCData emits only `{gcNodes}`; each route array is deduplicated preserving first insertion. Summary `unreferenced` does not automatically change unreferencedBlobSize: these helpers initialize that stat to zero and only merge values supplied by callers. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

Compact string IDs are persisted. Alphabet is exactly `ABCDEFGHIJKLMNOPQRSTUVWXYZ(abcdefghijklmnopqrstuvwxyz)0123456789`, 64 characters; 0→A, 1→B, 63→9, 64→AA, 100→Aj, 10000→BaQ, 100000→XZf. Prefix applies only for numeric input; string input is returned unchanged even if a prefix is passed. This is a decrement-after-division encoding, not standard base64/base64url or ordinary positional base64. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/utils.ts:1-109`

TelemetryContext serializes an object copied from a Map in insertion order, then JSON.stringify applies JS object key ordering/undefined omission. `setMultiple("p:","o",{a:1,b:2})` produces `{"p:o_a":1,"p:o_b":2}`. No telemetry blob is added to a document summary by this class. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

## 4. Behavior

### Handles and route identity

FluidHandleBase exposes self through IFluidHandle and symbol; it leaves absolutePath, attachGraph, isAttached and get abstract and supplies no bind method. isFluidHandle requires nonnull object with symbol (functions do not pass). toFluidHandleInternal requires the symbol on both wrapper and its symbol target; it returns the target, not wrapper, else TypeError Invalid IFluidHandle. compare uses exact absolutePath string equality. Pending external predicate accepts payloadState shared or pending; local predicate additionally requires payloadShareError property existence. Internal pending predicate needs property existence and strict true. lookupTemporaryBlobStorageId(containerRuntime,handle) converts the handle, requires absolutePath start `/_blobs/` or throws, splits on `/`, requires exactly three components with middle `_blobs` and nonempty final ID or throws Invalid blob handle path format, then delegates runtime.lookupTemporaryBlobStorageId(localId). Pending/detached storage IDs can return undefined; this helper does not resolve the handle. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:1-264`

getDataStorePackagePath converts the handle, requires runtime getDataStorePackagePath be a function, delegates its absolutePath and does not resolve a DDS. Missing runtime method throws TypeError; unknown datastore returns undefined. Lookup may fetch omitted snapshot attributes and change load timing. Remote handle is always attached, attachGraph no-ops. First get stores resolution promise; subsequent gets share it, including a cached rejection. No automatic retry or status==200 check. Constructor asserts absolute path; retained routeContext is the resolver. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:1-264` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/remoteFluidObjectHandle.ts:1-70`

### Path operations are deliberately different

GenerateHandleContextPath: empty input returns context absolutePath or empty root string. Nonempty input strips at most **one** leading and one trailing slash; absent parent prefixes `/`; parent `/` is treated as empty only in the concatenation. No URL decoding or dot-segment normalization. Storage path splitting similarly strips only one slash each side, returns [] for resulting empty string, otherwise splits preserving interior empty segments. `ObjectStoragePartition` asserts base has no trailing slash, forwards read/contains/list using literal `${base}/${path}`, and returns the original underlying snapshot tree unpartitioned. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/dataStoreHandleContextUtils.ts:1-39` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/objectstorageutils.ts:1-58` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/objectstoragepartition.ts:1-38`

RequestParser strips query from first `?`, drops empty slash-separated path segments, decodes each via decodeURIComponent and lazily caches parts. Query retains leading `?`; headers retain identity. create returns an existing RequestParser unchanged. isLeaf(n) requires exact part count AND no query. createSubRequest rejects index<0 or index>parts.length, but does not assert integer; index==length with original `?` emits `/${query}`. Otherwise joins **decoded** remaining parts with `/`, prefix `/`, then if query nonempty appends `/${query}`. It does not re-encode decoded slash/percent characters. Example `/a/b/?x=1`, index1→`/b/?x=1`, index2→`/?x=1`; `/a%2Fb` has one decoded part `a/b`, not two original parts. Malformed percent/UTF-8 escapes throw URIError. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/requestParser.ts:1-104`

listBlobsAtTreePath traverses only matching Tree entries, choosing first entry per path segment. Missing tree or leftover segments throws path does not exist; valid target returns only direct Blob entry names in entries order, excluding attachments/child trees. unpackChildNodesUsedRoutes removes only exact empty and `/` self routes, asserts every remaining route begins `/`, splits first child, slices relative remainder; `/a`→child a route empty, `/a/b`→child a route `/b`. Preserve duplicates in arrays and first child insertion order in Map. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/objectstorageutils.ts:1-58` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/unpackUsedRoutes.ts:1-37`

### Summary/statistics algorithms

mergeStats sums the five counters in argument order, zero args returns zeros. calculateStats recursively counts Tree, Blob, Handle; attachments/unknown tags do nothing. getBlobSize uses custom utf8ByteLength for strings and byteLength otherwise. That routine walks UTF-16 **backwards**: initialize s=code-unit length; add1 for codePointAt(i) in 0x80...0x7ff; add2 for 0x800...0xffff; after this, if low surrogate 0xdc00...0xdfff, decrement i an extra time. Well-formed pairs count4 bytes. An isolated low surrogate also skips its preceding unit: `"A\uDC00"` reports **4**; `"é\uDC00"` reports **4** instead of normal replacement UTF-8 size5. Lone high surrogate reports3. Port the literal loop, not Foundation UTF-8 sizing. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

addBlobToSummary assigns the key then increments blob count and byte size. addSummarizeResult assigns child then merges counters. Builder addHandle assigns then increments handle count; addAttachment assigns numeric counter key then advances counter, with no counters changed. Reusing a key overwrites content but still adds stats; don't silently recalculate stats or subtract old values. Summary getter clones child map but not children. ITree conversion enumerates Object.entries in JS key order; converting attachments through builder loses their original path in favor of numeric attachment counters. processAttachMessageGCData parses once, enumerates node entries then outbound arrays, calls callback for **every** edge including duplicates, returns true even if graph empty. Errors and callback throws propagate; no transaction rollback. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

GCDataBuilder addNode/addNodes overwrite a node's Set rather than union. prefixAndAddNodes strips **all** leading node slashes, constructs `/${prefixId}/${node}`, strips all trailing slashes (root `/` becomes `/${prefixId}`), then overwrites. Outbound strings are unchanged. addRouteToAllNodes adds once to each existing Set in object order. gcNodes getter returns new object/new arrays in object and Set order. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

Snapshot loading-group check first tests all local blob IDs in supplied Map; missing→true. Then recursively visits only child trees with groupId===undefined (empty string is a defined group and skipped). Returns false if all current-group blobs are present; does not fetch or mutate. seqFromTree reads `.protocol` tree's `attributes` blob and returns parsed sequenceNumber without additional validation. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/snapshotUtils.ts:1-38` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/utils.ts:1-109`

### Errors, initialization and compatibility

createResponseError forbids status200; strips query from request URL, appends `: ${urlNoQuery}` even for empty URL, creates stack lazily exposed through getter, returns text/plain status/value/stack/headers. create404Response uses404 and not found. responseToException returns a plain object, not Error instance: marker errorFromRequestFluidObject=true, message=response.value, name=Error, code=status, stack getter, underlyingResponseHeaders=response.headers. exceptionToResponse recognizes strict marker true on nonnull objects, restores code/message/headers; otherwise status500 and JS template string coercion `${error}`. Stack property existence, not nonundefined value, determines whether to reuse it. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/dataStoreHelpers.ts:1-183`

RuntimeFactoryHelper awaits preInitialize, then exactly one existing ? instantiateFromExisting : instantiateFirstTime, then hasInitialized, then returns runtime. Later hooks do not run if prior one rejects; default hooks are async no-ops. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/runtimeFactoryHelper.ts:1-59`

Compatibility floor/default both2.0.0; cleanedPackageVersion is featureVersion(pkgVersion), stripping prerelease and zeroing patch. Validation requires semver parse, no build metadata, >=floor, <=cleaned version, no prerelease, and major<3 OR patch==0; otherwise UsageError with verbose predicates. Config iterable validates each entry version, copies/sorts descending via semver comparator, then selects first key<=requested version; missing selection fails0xcb8. `getConfigsForMinVersionForCollab` additionally validates requested version before iterating configs. Generic selectVersionRoundedDown does not impose deployed-version validation. Stable equal-key sorting keeps input order. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/compatibilityBase.ts:1-376`

Overrides iterate own entries; skip keys not present via `in` in validationMap; validator undefined permits, version greater than requested throws UsageError. configValueToMinVersionForCollab uses Map lookup for nonobjects; object case requires all iterated possible values be objects, matches if **any one** key's value is strictly equal, collects required versions, returns greatest semver, otherwise undefined. It is shallow partial matching, not deep equality nor all-key matching. Null is typeof object and is not specially protected by the implementation. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/compatibilityBase.ts:1-376`

### Service adapters

DataStoreKindImplementation wraps a factory; type is copied, optional createDataStore is bound to original factory, instantiate delegates. adapt accepts only exact self; same-type different instance throws conflict UsageError, different type throws mismatch. normalizeRegistry wraps a recognized kind as constant async registry or asserts function. convertRegistry looks up a basic key then requires DataStoreKindImplementation. makeCodeLoader always satisfies=true/compare=0; load echoes details and returns fluidExport. EntryPoint resolves alias `root`, throws Root data store missing! if absent, otherwise awaits handle.get. loadRuntime receives context, converted registry, provideEntryPoint, existing, oldestSupportedClient, newContainerRootType=root?.type (the implementation includes this property even on existing loads). Root creation/aliasing is the callback's responsibility. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientBase.ts:1-261` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientUtils.ts:1-239`

ServiceContainerBase.attach: reject already id-bearing, reject already-started, assert Detached; set startedAttach=true; create request and await container.attach; assert Attached; assign resolved id, return self. No finally/reset: a failed attach does not enable another attempt. audience forwards, close delegates. createDataStore: lookup kind, narrow, get runtime, createDetachedDataStore([kind.type]), await instantiate(context,false), await attachRuntime, await entryPoint.get, return data. ServiceClient createContainer uses supplied registry lookup or recognized direct kind; createAttachedContainer awaits createContainer then attach; loadContainer normalizes registry then statics.load. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientBase.ts:1-261` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientUtils.ts:1-239`

### handles: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:1-264`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export interface ISerializedHandle {
	type: "__fluid_handle__";
	url: string;
	readonly payloadPending?: true;
}
export const isSerializedHandle = (value: unknown): value is ISerializedHandle =>
	(value as { type?: string } | undefined)?.type === "__fluid_handle__";
export const isFluidHandleInternalPayloadPending = (
	fluidHandleInternal: IFluidHandleInternal,
): fluidHandleInternal is IFluidHandleInternalPayloadPending =>
	"payloadPending" in fluidHandleInternal && fluidHandleInternal.payloadPending === true;
export const isFluidHandlePayloadPending = <T>(
	handle: IFluidHandle<T>,
): handle is IFluidHandlePayloadPending<T> =>
	"payloadState" in handle &&
	(handle.payloadState === "shared" || handle.payloadState === "pending");
export const isLocalFluidHandle = <T>(
	handle: IFluidHandle<T>,
): handle is ILocalFluidHandle<T> =>
	isFluidHandlePayloadPending(handle) && "payloadShareError" in handle;
export function encodeHandleForSerialization(handle: IFluidHandleInternal): ISerializedHandle {
	return isFluidHandleInternalPayloadPending(handle)
		? {
				type: "__fluid_handle__",
				url: handle.absolutePath,
				payloadPending: true,
			}
		: {
				type: "__fluid_handle__",
				url: handle.absolutePath,
			};
}
export function isFluidHandle(value: unknown): value is IFluidHandle {
	return typeof value === "object" && value !== null && fluidHandleSymbol in value;
}
export function compareFluidHandles(a: IFluidHandle, b: IFluidHandle): boolean {
	const aInternal = toFluidHandleInternal(a);
	const bInternal = toFluidHandleInternal(b);
	return aInternal.absolutePath === bInternal.absolutePath;
}
function hasDataStorePackagePath(
	runtime: IContainerRuntimeBase,
): runtime is IContainerRuntimeBase &
	Pick<IContainerRuntimeBaseInternal, "getDataStorePackagePath"> {
	return (
		"getDataStorePackagePath" in runtime &&
		typeof runtime.getDataStorePackagePath === "function"
	);
}
export async function getDataStorePackagePath(
	containerRuntime: IContainerRuntimeBase,
	handle: IFluidHandle,
): Promise<PackagePath | undefined> {
	const nodePath = toFluidHandleInternal(handle).absolutePath;
	if (!hasDataStorePackagePath(containerRuntime)) {
		throw new TypeError("Container runtime does not support data store package path lookup");
	}
	return containerRuntime.getDataStorePackagePath(nodePath);
}
export function toFluidHandleInternal<T>(handle: IFluidHandle<T>): IFluidHandleInternal<T> {
	if (!(fluidHandleSymbol in handle) || !(fluidHandleSymbol in handle[fluidHandleSymbol])) {
		throw new TypeError("Invalid IFluidHandle");
	}
	return handle[fluidHandleSymbol] as unknown as IFluidHandleInternal<T>;
}
export function toFluidHandleErased<T>(
	handle: IFluidHandleInternal<T>,
): IFluidHandleErased<T> {
	return handle as unknown as IFluidHandleErased<T>;
}
export abstract class FluidHandleBase<T> implements IFluidHandleInternal<T> {
	public abstract absolutePath: string;
	public abstract attachGraph(): void;
	public abstract readonly isAttached: boolean;
	public abstract get(): Promise<T>;
	public get IFluidHandle(): IFluidHandleInternal {
		return this;
	}
	public get [fluidHandleSymbol](): IFluidHandleErased<T> {
		return toFluidHandleErased(this);
	}
}
export function lookupTemporaryBlobStorageId(
	containerRuntime: IContainerRuntime,
	handle: IFluidHandle,
): string | undefined {
	const absolutePath: string | undefined = toFluidHandleInternal(handle).absolutePath;
	if (!absolutePath?.startsWith("/_blobs/")) {
		throw new Error(
			"Handle does not point to a blob - expected path to start with '/_blobs/'",
		);
	}
	const pathParts = absolutePath.split("/");
	if (
		pathParts.length !== 3 ||
		pathParts[1] !== "_blobs" ||
		pathParts[2] === undefined ||
		pathParts[2] === ""
	) {
		throw new Error("Invalid blob handle path format");
	}
	const localId = pathParts[2];
	const internalRuntime = containerRuntime as IContainerRuntimeInternal;
	return internalRuntime.lookupTemporaryBlobStorageId(localId);
}
```

### remoteFluidObjectHandle: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/remoteFluidObjectHandle.ts:1-70`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export class RemoteFluidObjectHandle extends FluidHandleBase<FluidObject> {
	public readonly isAttached = true;
	private objectP: Promise<FluidObject> | undefined;
	public constructor(
		public readonly absolutePath: string,
		public readonly routeContext: IFluidHandleContext,
		public readonly payloadPending: boolean,
	) {
		super();
		assert(
			absolutePath.startsWith("/"),
			0x19d ,
		);
	}
	public async get(): Promise<FluidObject> {
		if (this.objectP === undefined) {
			const request: IRequest = {
				url: this.absolutePath,
				headers: {
					[RuntimeHeaders.viaHandle]: true,
					[RuntimeHeaders.payloadPending]: this.payloadPending,
				},
			};
			this.objectP = this.routeContext.resolveHandle(request).then<FluidObject>((response) => {
				if (response.mimeType === "fluid/object") {
					const fluidObject: FluidObject = response.value as FluidObject;
					return fluidObject;
				}
				throw responseToException(response, request);
			});
		}
		return this.objectP;
	}
	public attachGraph(): void {
		return;
	}
}
```

### dataStoreHandleContextUtils: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/dataStoreHandleContextUtils.ts:1-39`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export function generateHandleContextPath(
	path: string,
	routeContext?: IFluidHandleContext,
): string {
	if (path === "") {
		return routeContext === undefined ? "" : routeContext.absolutePath;
	} else {
		let normalizedPath = path.startsWith("/") ? path.slice(1) : path;
		normalizedPath = normalizedPath.endsWith("/")
			? normalizedPath.slice(0, -1)
			: normalizedPath;
		return routeContext === undefined
			? `/${normalizedPath}`
			: `${
					routeContext.absolutePath === "/" ? "" : routeContext.absolutePath
				}/${normalizedPath}`;
	}
}
```

### requestParser: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/requestParser.ts:1-104`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export class RequestParser implements IRequest {
	public static getPathParts(url: string): readonly string[] {
		const queryStartIndex = url.indexOf("?");
		const pathParts: string[] = [];
		const urlPath = url.slice(0, queryStartIndex < 0 ? url.length : queryStartIndex);
		for (const part of urlPath.split("/")) {
			if (part !== undefined && part.length > 0) {
				pathParts.push(decodeURIComponent(part));
			}
		}
		return pathParts;
	}
	private requestPathParts: readonly string[] | undefined;
	public readonly query: string;
	public static create(request: Readonly<IRequest>): RequestParser {
		if (request instanceof RequestParser) {
			return request;
		}
		return new RequestParser(request);
	}
	protected constructor(private readonly request: Readonly<IRequest>) {
		const queryStartIndex = this.request.url.indexOf("?");
		this.query = queryStartIndex >= 0 ? this.request.url.slice(queryStartIndex) : "";
		if (request.headers !== undefined) {
			this.headers = request.headers;
		}
	}
	public get url(): string {
		return this.request.url;
	}
	public readonly headers?: IRequestHeader;
	public get pathParts(): readonly string[] {
		if (this.requestPathParts === undefined) {
			this.requestPathParts = RequestParser.getPathParts(this.url);
		}
		return this.requestPathParts;
	}
	public isLeaf(elements: number): boolean {
		return this.query === "" && this.pathParts.length === elements;
	}
	public createSubRequest(startingPathIndex: number): IRequest {
		const pathLen = this.pathParts.length;
		if (startingPathIndex < 0 || startingPathIndex > pathLen) {
			throw new Error("incorrect sub-request");
		}
		if (startingPathIndex === pathLen && this.url.includes("?")) {
			return {
				url: `/${this.query}`,
				headers: this.headers,
			};
		}
		const path = `/${this.pathParts.slice(startingPathIndex).join("/")}`;
		return {
			url: this.query === "" ? path : `${path}/${this.query}`,
			headers: this.headers,
		};
	}
}
```

### objectstoragepartition: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/objectstoragepartition.ts:1-38`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export class ObjectStoragePartition implements IChannelStorageService {
	public constructor(
		private readonly storage: IChannelStorageService,
		private readonly path: string,
	) {
		assert(!path.endsWith("/"), 0x19c );
	}
	public async readBlob(path: string): Promise<ArrayBufferLike> {
		return this.storage.readBlob(`${this.path}/${path}`);
	}
	public async contains(path: string): Promise<boolean> {
		return this.storage.contains(`${this.path}/${path}`);
	}
	public async list(path: string): Promise<string[]> {
		return this.storage.list(`${this.path}/${path}`);
	}
	public getSnapshotTree(): ISnapshotTree | undefined {
		return this.storage.getSnapshotTree();
	}
}
```

### objectstorageutils: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/objectstorageutils.ts:1-58`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export function getNormalizedObjectStoragePathParts(path: string): string[] {
	let normalizePath = path;
	if (normalizePath.startsWith("/")) {
		normalizePath = normalizePath.slice(1);
	}
	if (normalizePath.endsWith("/")) {
		normalizePath = normalizePath.slice(0, -1);
	}
	if (normalizePath.length > 0) {
		return normalizePath.split("/");
	}
	return [];
}
export async function listBlobsAtTreePath(
	inputTree: ITree | undefined,
	path: string,
): Promise<string[]> {
	const pathParts = getNormalizedObjectStoragePathParts(path);
	let tree: ITree | undefined = inputTree;
	while (tree?.entries !== undefined && pathParts.length > 0) {
		const part = pathParts.shift();
		const treeEntry = tree.entries.find((value) => {
			return value.type === TreeEntry.Tree && value.path === part ? true : false;
		});
		tree = treeEntry?.type === TreeEntry.Tree ? treeEntry.value : undefined;
	}
	if (tree?.entries === undefined || pathParts.length > 0) {
		throw new Error("path does not exist");
	}
	return tree.entries.filter((e) => e.type === TreeEntry.Blob).map((e) => e.path);
}
```

### summaryUtils: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export function mergeStats(...stats: ISummaryStats[]): ISummaryStats {
	const results = {
		treeNodeCount: 0,
		blobNodeCount: 0,
		handleNodeCount: 0,
		totalBlobSize: 0,
		unreferencedBlobSize: 0,
	};
	for (const stat of stats) {
		results.treeNodeCount += stat.treeNodeCount;
		results.blobNodeCount += stat.blobNodeCount;
		results.handleNodeCount += stat.handleNodeCount;
		results.totalBlobSize += stat.totalBlobSize;
		results.unreferencedBlobSize += stat.unreferencedBlobSize;
	}
	return results;
}
export function utf8ByteLength(str: string): number {
	let s = str.length;
	for (let i = str.length - 1; i >= 0; i--) {
		const code = str.codePointAt(i);
		if (code !== undefined) {
			if (code > 0x7f && code <= 0x7ff) {
				s++;
			} else if (code > 0x7ff && code <= 0xffff) {
				s += 2;
			}
			if (code >= 0xdc00 && code <= 0xdfff) {
				i--; 
			}
		}
	}
	return s;
}
export function getBlobSize(content: ISummaryBlob["content"]): number {
	return typeof content === "string" ? utf8ByteLength(content) : content.byteLength;
}
function calculateStatsCore(summaryObject: SummaryObject, stats: ISummaryStats): void {
	switch (summaryObject.type) {
		case SummaryType.Tree: {
			stats.treeNodeCount++;
			for (const value of Object.values(summaryObject.tree)) {
				calculateStatsCore(value, stats);
			}
			return;
		}
		case SummaryType.Handle: {
			stats.handleNodeCount++;
			return;
		}
		case SummaryType.Blob: {
			stats.blobNodeCount++;
			stats.totalBlobSize += getBlobSize(summaryObject.content);
			return;
		}
		default: {
			return;
		}
	}
}
export function calculateStats(summary: SummaryObject): ISummaryStats {
	const stats = mergeStats();
	calculateStatsCore(summary, stats);
	return stats;
}
export function addBlobToSummary(
	summary: ISummaryTreeWithStats,
	key: string,
	content: string | Uint8Array,
): void {
	const blob: ISummaryBlob = {
		type: SummaryType.Blob,
		content,
	};
	summary.summary.tree[key] = blob;
	summary.stats.blobNodeCount++;
	summary.stats.totalBlobSize += getBlobSize(content);
}
export function addSummarizeResultToSummary(
	summary: ISummaryTreeWithStats,
	key: string,
	summarizeResult: ISummarizeResult,
): void {
	summary.summary.tree[key] = summarizeResult.summary;
	summary.stats = mergeStats(summary.stats, summarizeResult.stats);
}
export interface SummaryTreeBuilderParams {
	groupId?: string;
}
export class SummaryTreeBuilder implements ISummaryTreeWithStats {
	private attachmentCounter: number = 0;
	private readonly groupId?: string;
	public get summary(): ISummaryTree {
		const summary: ISummaryTree = {
			type: SummaryType.Tree,
			tree: { ...this.summaryTree },
		};
		if (this.groupId !== undefined) {
			summary.groupId = this.groupId;
		}
		return summary;
	}
	public get stats(): Readonly<ISummaryStats> {
		return { ...this.summaryStats };
	}
	public constructor(params?: { groupId?: string }) {
		this.summaryStats = mergeStats();
		this.summaryStats.treeNodeCount++;
		this.groupId = params?.groupId;
	}
	private readonly summaryTree: Record<string, SummaryObject> = {};
	private summaryStats: ISummaryStats;
	public addBlob(key: string, content: string | Uint8Array): void {
		addBlobToSummary(
			{
				summary: {
					type: SummaryType.Tree,
					tree: this.summaryTree,
				},
				stats: this.summaryStats,
			},
			key,
			content,
		);
	}
	public addHandle(
		key: string,
		handleType: SummaryType.Tree | SummaryType.Blob | SummaryType.Attachment,
		handle: string,
	): void {
		this.summaryTree[key] = {
			type: SummaryType.Handle,
			handleType,
			handle,
		};
		this.summaryStats.handleNodeCount++;
	}
	public addWithStats(key: string, summarizeResult: ISummarizeResult): void {
		this.summaryTree[key] = summarizeResult.summary;
		this.summaryStats = mergeStats(this.summaryStats, summarizeResult.stats);
	}
	public addAttachment(id: string): void {
		this.summaryTree[this.attachmentCounter++] = { id, type: SummaryType.Attachment };
	}
	public getSummaryTree(): ISummaryTreeWithStats {
		return { summary: this.summary, stats: this.stats };
	}
}
export function convertToSummaryTreeWithStats(
	snapshot: ITree,
	fullTree: boolean = false,
): ISummaryTreeWithStats {
	const builder = new SummaryTreeBuilder();
	for (const entry of snapshot.entries) {
		switch (entry.type) {
			case TreeEntry.Blob: {
				const blob = entry.value;
				const content =
					blob.encoding === "base64" ? IsoBuffer.from(blob.contents, "base64") : blob.contents;
				builder.addBlob(entry.path, content);
				break;
			}
			case TreeEntry.Tree: {
				const subtree = convertToSummaryTree(entry.value, fullTree);
				builder.addWithStats(entry.path, subtree);
				break;
			}
			case TreeEntry.Attachment: {
				const id = entry.value.id;
				builder.addAttachment(id);
				break;
			}
			default: {
				throw new Error("Unexpected TreeEntry type");
			}
		}
	}
	const summaryTree = builder.getSummaryTree();
	summaryTree.summary.unreferenced = snapshot.unreferenced;
	summaryTree.summary.groupId = snapshot.groupId;
	return summaryTree;
}
export function convertToSummaryTree(
	snapshot: ITree,
	fullTree: boolean = false,
): ISummarizeResult {
	if (snapshot.id && !fullTree) {
		const stats = mergeStats();
		stats.handleNodeCount++;
		return {
			summary: {
				handle: snapshot.id,
				handleType: SummaryType.Tree,
				type: SummaryType.Handle,
			},
			stats,
		};
	} else {
		return convertToSummaryTreeWithStats(snapshot, fullTree);
	}
}
export function convertSnapshotTreeToSummaryTree(
	snapshot: ISnapshotTreeWithBlobContents,
): ISummaryTreeWithStats {
	const builder = new SummaryTreeBuilder();
	for (const [path, id] of Object.entries(snapshot.blobs)) {
		let decoded: string | undefined;
		if (snapshot.blobsContents !== undefined) {
			const content: ArrayBufferLike = snapshot.blobsContents[id]!;
			if (content !== undefined) {
				decoded = bufferToString(content, "utf-8");
			}
		} else if (snapshot.blobs[id] !== undefined) {
			decoded = fromBase64ToUtf8(snapshot.blobs[id]);
		}
		if (decoded !== undefined) {
			builder.addBlob(path, decoded);
		}
	}
	for (const [key, tree] of Object.entries(snapshot.trees)) {
		const subtree = convertSnapshotTreeToSummaryTree(tree);
		builder.addWithStats(key, subtree);
	}
	const summaryTree = builder.getSummaryTree();
	summaryTree.summary.unreferenced = snapshot.unreferenced;
	summaryTree.summary.groupId = snapshot.groupId;
	return summaryTree;
}
export function convertSummaryTreeToITree(summaryTree: ISummaryTree): ITree {
	const entries: ITreeEntry[] = [];
	for (const [key, value] of Object.entries(summaryTree.tree)) {
		switch (value.type) {
			case SummaryType.Blob: {
				let parsedContent: string;
				let encoding: "utf-8" | "base64" = "utf-8";
				if (typeof value.content === "string") {
					parsedContent = value.content;
				} else {
					parsedContent = Uint8ArrayToString(value.content, "base64");
					encoding = "base64";
				}
				entries.push(new BlobTreeEntry(key, parsedContent, encoding));
				break;
			}
			case SummaryType.Tree: {
				entries.push(new TreeTreeEntry(key, convertSummaryTreeToITree(value)));
				break;
			}
			case SummaryType.Attachment: {
				entries.push(new AttachmentTreeEntry(key, value.id));
				break;
			}
			case SummaryType.Handle: {
				throw new Error("Should not have Handle type in summary tree");
			}
			default: {
				unreachableCase(value, "Unexpected summary tree type");
			}
		}
	}
	return {
		entries,
		unreferenced: summaryTree.unreferenced,
		groupId: summaryTree.groupId,
	};
}
export function processAttachMessageGCData(
	snapshot: ITree | undefined,
	addedGCOutboundRoute: (fromNodeId: string, toPath: string) => void,
): boolean {
	const gcDataEntry = snapshot?.entries.find((e) => e.path === gcDataBlobKey);
	if (gcDataEntry === undefined) {
		return false;
	}
	assert(
		gcDataEntry.type === TreeEntry.Blob && gcDataEntry.value.encoding === "utf-8",
		0x8ff ,
	);
	const gcData = JSON.parse(gcDataEntry.value.contents) as IGarbageCollectionData;
	for (const [nodeId, outboundRoutes] of Object.entries(gcData.gcNodes)) {
		for (const toPath of outboundRoutes) {
			addedGCOutboundRoute(nodeId, toPath);
		}
	}
	return true;
}
export class TelemetryContext implements ITelemetryContext, ITelemetryContextExt {
	private readonly telemetry = new Map<string, TelemetryEventPropertyTypeExt>();
	public set(prefix: string, property: string, value: TelemetryEventPropertyTypeExt): void {
		this.telemetry.set(`${prefix}${property}`, value);
	}
	public setMultiple(
		prefix: string,
		property: string,
		values: Record<string, TelemetryEventPropertyTypeExt>,
	): void {
		for (const key of Object.keys(values)) {
			this.set(prefix, `${property}_${key}`, values[key]);
		}
	}
	public get(prefix: string, property: string): TelemetryEventPropertyTypeExt {
		return this.telemetry.get(`${prefix}${property}`);
	}
	public serialize(): string {
		const jsonObject = {};
		for (const [key, value] of this.telemetry.entries()) {
			jsonObject[key] = value;
		}
		return JSON.stringify(jsonObject);
	}
	public getCurrentSummarizeStep(): TelemetryEventPropertyTypeExt {
		return this.get(currentSummarizeStepPrefix, currentSummarizeStepPropertyName);
	}
	public setCurrentSummarizeStep(value: TelemetryEventPropertyTypeExt): void {
		this.set(currentSummarizeStepPrefix, currentSummarizeStepPropertyName, value);
	}
}
function trimLeadingSlashes(str: string): string {
	return str.replace(/^\/+/g, "");
}
function trimTrailingSlashes(str: string): string {
	return str.replace(/\/+$/g, "");
}
export class GCDataBuilder implements IGarbageCollectionData {
	private readonly gcNodesSet: Record<string, Set<string>> = {};
	public get gcNodes(): Record<string, string[]> {
		const gcNodes = {};
		for (const [nodeId, outboundRoutes] of Object.entries(this.gcNodesSet)) {
			gcNodes[nodeId] = [...outboundRoutes];
		}
		return gcNodes;
	}
	public addNode(id: string, outboundRoutes: string[]): void {
		this.gcNodesSet[id] = new Set(outboundRoutes);
	}
	public prefixAndAddNodes(prefixId: string, gcNodes: Record<string, string[]>): void {
		for (const [id, outboundRoutes] of Object.entries(gcNodes)) {
			let normalizedId = trimLeadingSlashes(id);
			normalizedId = `/${prefixId}/${normalizedId}`;
			normalizedId = trimTrailingSlashes(normalizedId);
			this.gcNodesSet[normalizedId] = new Set(outboundRoutes);
		}
	}
	public addNodes(gcNodes: Record<string, string[]>): void {
		for (const [id, outboundRoutes] of Object.entries(gcNodes)) {
			this.gcNodesSet[id] = new Set(outboundRoutes);
		}
	}
	public addRouteToAllNodes(outboundRoute: string): void {
		for (const outboundRoutes of Object.values(this.gcNodesSet)) {
			outboundRoutes.add(outboundRoute);
		}
	}
	public getGCData(): IGarbageCollectionData {
		return {
			gcNodes: this.gcNodes,
		};
	}
}
```

### unpackUsedRoutes: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/unpackUsedRoutes.ts:1-37`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export function unpackChildNodesUsedRoutes(
	usedRoutes: readonly string[],
): Map<string, string[]> {
	const filteredUsedRoutes = usedRoutes.filter((route) => route !== "" && route !== "/");
	const childUsedRoutesMap = new Map<string, string[]>();
	for (const route of filteredUsedRoutes) {
		assert(route.startsWith("/"), 0x5e0 );
		const childId = route.split("/")[1];
		assert(
			childId !== undefined,
			0x9ab ,
		);
		const childUsedRoute = route.slice(childId.length + 1);
		const childUsedRoutes = childUsedRoutesMap.get(childId);
		if (childUsedRoutes === undefined) {
			childUsedRoutesMap.set(childId, [childUsedRoute]);
		} else {
			childUsedRoutes.push(childUsedRoute);
		}
	}
	return childUsedRoutesMap;
}
```

### utils: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/utils.ts:1-109`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export enum RuntimeHeaders {
	wait = "wait",
	viaHandle = "viaHandle",
	payloadPending = "payloadPending",
}
export type ReadAndParseBlob = <T>(id: string) => Promise<T>;
export async function seqFromTree(
	tree: ISnapshotTree,
	readAndParseBlob: ReadAndParseBlob,
): Promise<number> {
	const attributesHash = tree.trees[".protocol"]!.blobs.attributes!;
	const attrib = await readAndParseBlob<IDocumentAttributes>(attributesHash);
	return attrib.sequenceNumber;
}
export const charSetForEncodingIds =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZ(abcdefghijklmnopqrstuvwxyz)0123456789";
export function encodeCompactIdToString(idArg: number | string, prefix = ""): string {
	if (typeof idArg === "string") {
		return idArg;
	}
	assert(Number.isInteger(idArg) && idArg >= 0, 0x900 );
	let id = "";
	let num = idArg;
	do {
		const encode = num % 64;
		id = charSetForEncodingIds[encode] + id;
		num = Math.floor(num / 64) - 1;
	} while (num !== -1);
	return prefix + id;
}
```

### snapshotUtils: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/snapshotUtils.ts:1-38`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export function isSnapshotFetchRequiredForLoadingGroupId(
	snapshotTree: ISnapshotTree,
	blobContents: Map<string, ArrayBuffer>,
): boolean {
	for (const [_, id] of Object.entries(snapshotTree.blobs)) {
		if (!blobContents.has(id)) {
			return true;
		}
	}
	for (const [_, childTree] of Object.entries(snapshotTree.trees)) {
		if (childTree.groupId === undefined) {
			const value = isSnapshotFetchRequiredForLoadingGroupId(childTree, blobContents);
			if (value) {
				return true;
			}
		}
	}
	return false;
}
```

### dataStoreHelpers: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/dataStoreHelpers.ts:1-183`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
interface IResponseException extends Error {
	errorFromRequestFluidObject: true;
	message: string;
	code: number;
	stack?: string;
	underlyingResponseHeaders?: Record<string, unknown>;
}
function isResponseException(err: unknown): err is IResponseException {
	return (
		err !== null &&
		typeof err === "object" &&
		"errorFromRequestFluidObject" in err &&
		(err as { errorFromRequestFluidObject: unknown }).errorFromRequestFluidObject === true
	);
}
export function exceptionToResponse(error: unknown): IResponse {
	const status = 500;
	if (isResponseException(error)) {
		return {
			mimeType: "text/plain",
			status: error.code,
			value: error.message,
			get stack() {
				return error.stack;
			},
			headers: error.underlyingResponseHeaders,
		};
	}
	const errWithStack =
		typeof error === "object" && error !== null && "stack" in error
			? (error as { stack: string })
			: generateErrorWithStack();
	return {
		mimeType: "text/plain",
		status,
		value: `${error}`,
		get stack() {
			return errWithStack.stack;
		},
	};
}
export function responseToException(response: IResponse, request: IRequest): Error {
	const message = response.value as string;
	const errWithStack = "stack" in response ? response : generateErrorWithStack();
	const responseErr: Error & IResponseException = {
		errorFromRequestFluidObject: true,
		message,
		name: "Error",
		code: response.status,
		get stack() {
			return errWithStack.stack;
		},
		underlyingResponseHeaders: response.headers,
	};
	return responseErr;
}
export const create404Response = (request: IRequest): IResponse =>
	createResponseError(404, "not found", request);
export function createResponseError(
	status: number,
	value: string,
	request: IRequest,
	headers?: Record<string, unknown>,
): IResponse {
	assert(status !== 200, 0x19b );
	const urlNoQuery = request.url?.split("?")[0];
	const errWithStack = generateErrorWithStack();
	return {
		mimeType: "text/plain",
		status,
		value: urlNoQuery === undefined ? value : `${value}: ${urlNoQuery}`,
		get stack() {
			return errWithStack.stack;
		},
		headers,
	};
}
export function dataStoreLoadTelemetryProps(props: {
	id: string;
	packagePath: readonly string[];
}): ITelemetryPropertiesExt {
	const { id, packagePath } = props;
	const dataStorePackagePath = packagePath.length > 0 ? packagePath.join("/") : undefined;
	return tagCodeArtifacts({
		dataStorePackagePath, 
		dataStoreId: id, 
	});
}
export function asLegacyAlpha(runtime: IContainerRuntimeBase): ContainerRuntimeBaseAlpha;
export function asLegacyAlpha(runtime: IFluidDataStoreRuntime): IFluidDataStoreRuntimeAlpha;
export function asLegacyAlpha(
	runtime: IFluidDataStoreRuntime | IContainerRuntimeBase,
): unknown {
	return runtime;
}
```

### runtimeFactoryHelper: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/runtimeFactoryHelper.ts:1-59`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export abstract class RuntimeFactoryHelper<T = IContainerRuntime> implements IRuntimeFactory {
	public get IRuntimeFactory(): this {
		return this;
	}
	public async instantiateRuntime(
		context: IContainerContext,
		existing: boolean,
	): Promise<IRuntime> {
		const runtime = await this.preInitialize(context, existing);
		await (existing
			? this.instantiateFromExisting(runtime)
			: this.instantiateFirstTime(runtime));
		await this.hasInitialized(runtime);
		return runtime;
	}
	public abstract preInitialize(
		context: IContainerContext,
		existing: boolean,
	): Promise<IRuntime & T>;
	public async instantiateFirstTime(_runtime: T): Promise<void> {}
	public async instantiateFromExisting(_runtime: T): Promise<void> {}
	public async hasInitialized(_runtime: T): Promise<void> {}
}
```

### compatibilityBase: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/compatibilityBase.ts:1-376`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export const lowestMinVersionForCollab =
	"2.0.0" as const satisfies OldestSupportedClientVersion;
export const defaultMinVersionForCollab = lowestMinVersionForCollab;
export type MinimumMinorSemanticVersion = `${bigint}.${bigint}.0`;
export type SemanticVersion =
	| `${bigint}.${bigint}.${bigint}`
	| `${bigint}.${bigint}.${bigint}-${string}`;
export type ConfigMap<T extends Record<string, unknown>> = {
	readonly [K in keyof T]-?: ConfigMapEntry<T[K]>;
};
export interface ConfigMapEntry<T> {
	[version: MinimumMinorSemanticVersion]: T;
	[lowestMinVersionForCollab]: T;
}
export type ConfigValidationMap<T extends Record<string, unknown>> = {
	readonly [K in keyof T]-?: (configValue: T[K]) => SemanticVersion | undefined;
};
export function getConfigsForMinVersionForCollab<T extends Record<SemanticVersion, unknown>>(
	minVersionForCollab: OldestSupportedClientVersion,
	configMap: ConfigMap<T> & Record<keyof T, unknown>,
): T {
	validateMinimumVersionForCollab(minVersionForCollab);
	const defaultConfigs: Partial<T> = {};
	for (const [key, config] of Object.entries(configMap)) {
		defaultConfigs[key] = getConfigForMinVersionForCollab(
			minVersionForCollab,
			config as ConfigMapEntry<unknown>,
		);
	}
	return defaultConfigs as T;
}
export function getConfigForMinVersionForCollab<T>(
	minVersionForCollab: OldestSupportedClientVersion,
	config: ConfigMapEntry<T>,
): T {
	return getConfigForMinVersionForCollabIterable(
		minVersionForCollab,
		Object.entries(config) as [MinimumMinorSemanticVersion, T][],
	);
}
export function getConfigForMinVersionForCollabIterable<T>(
	minVersionForCollab: OldestSupportedClientVersion,
	entries: Iterable<readonly [MinimumMinorSemanticVersion | OldestSupportedClientVersion, T]>, 
): T {
	const versions: [OldestSupportedClientVersion, T][] = Array.from(
		entries,
		([version, value]) => {
			validateMinimumVersionForCollab(version);
			return [version, value];
		},
	);
	return (selectVersionRoundedDown(minVersionForCollab, versions) ??
		fail(0xcb8 ))[1];
}
export function selectVersionRoundedDown<T>(
	minVersionForCollab: string,
	entries: Iterable<readonly [string, T]>,
	compareVersions: (a: string, b: string) => number = compare,
): readonly [string, T] | undefined {
	const versions: (readonly [string, T])[] = [...entries];
	versions.sort((a, b) => compareVersions(b[0], a[0]));
	for (const pair of versions) {
		const [version, _] = pair;
		if (compareVersions(minVersionForCollab, version) >= 0) {
			return pair;
		}
	}
	return undefined;
}
export function checkValidMinVersionForCollabVerbose(minVersionForCollab: SemanticVersion): {
	isValidSemver: boolean;
	isGteLowestMinVersion: boolean;
	isLtePkgVersion: boolean;
	isValidOldestSupportedClientVersion: boolean;
} {
	const parsed = parse(minVersionForCollab);
	const isValidSemver = parsed !== null && parsed.build.length === 0;
	const isGteLowestMinVersion =
		isValidSemver && gte(minVersionForCollab, lowestMinVersionForCollab);
	const isLtePkgVersion = isValidSemver && lte(minVersionForCollab, cleanedPackageVersion);
	const isValidOldestSupportedClientVersion =
		isGteLowestMinVersion &&
		isLtePkgVersion &&
		parsed !== null &&
		parsed.prerelease.length === 0 &&
		(parsed.major < 3 || parsed.patch === 0);
	return {
		isValidSemver,
		isGteLowestMinVersion,
		isLtePkgVersion,
		isValidOldestSupportedClientVersion,
	};
}
export function isValidMinVersionForCollab(
	minVersionForCollab: SemanticVersion,
): minVersionForCollab is OldestSupportedClientVersion {
	return checkValidMinVersionForCollabVerbose(minVersionForCollab)
		.isValidOldestSupportedClientVersion;
}
export const cleanedPackageVersion = featureVersion(
	pkgVersion,
) satisfies OldestSupportedClientVersion;
export function validateMinimumVersionForCollab(
	semanticVersion: string,
): asserts semanticVersion is OldestSupportedClientVersion {
	const minVersionForCollab = semanticVersion as OldestSupportedClientVersion;
	const {
		isValidSemver,
		isGteLowestMinVersion,
		isLtePkgVersion,
		isValidOldestSupportedClientVersion,
	} = checkValidMinVersionForCollabVerbose(minVersionForCollab);
	if (!isValidOldestSupportedClientVersion) {
		throw new UsageError(
			`Version ${minVersionForCollab} is not a valid OldestSupportedClientVersion. ` +
				`It must be in a valid semver format, at least ${lowestMinVersionForCollab}, ` +
				`less than or equal to the current package version ${cleanedPackageVersion}, ` +
				`have no prerelease component, and use patch version 0 for major version 3 and later. ` +
				`Use "featureVersion" to normalize a package version to the correct format. ` +
				`Details: { isValidSemver: ${isValidSemver}, isGteLowestMinVersion: ${isGteLowestMinVersion}, isLtePkgVersion: ${isLtePkgVersion}, isValidOldestSupportedClientVersion: ${isValidOldestSupportedClientVersion} }`,
		);
	}
}
export function validateConfigMapOverrides<T extends Record<string, unknown>>(
	minVersionForCollab: SemanticVersion,
	overrides: Partial<T>,
	validationMap: ConfigValidationMap<T>,
): void {
	for (const [passedRuntimeOption, passedRuntimeOptionValue] of Object.entries(overrides) as [
		keyof T & string,
		T[keyof T & string],
	][]) {
		if (!(passedRuntimeOption in validationMap)) {
			continue;
		}
		const requiredVersion = validationMap[passedRuntimeOption](passedRuntimeOptionValue);
		if (requiredVersion !== undefined && gt(requiredVersion, minVersionForCollab)) {
			throw new UsageError(
				`Runtime option ${passedRuntimeOption}:${JSON.stringify(passedRuntimeOptionValue)} requires ` +
					`runtime version ${requiredVersion}. Please update minVersionForCollab ` +
					`(currently ${minVersionForCollab}) to ${requiredVersion} or later to proceed.`,
			);
		}
	}
}
export function configValueToMinVersionForCollab<
	T extends string | number | boolean | undefined | object,
	Arr extends readonly [T, SemanticVersion][],
>(configToMinVer: Arr): (configValue: T) => SemanticVersion | undefined {
	const configValueToRequiredVersionMap = new Map(configToMinVer);
	return (configValue: T) => {
		if (typeof configValue !== "object") {
			return configValueToRequiredVersionMap.get(configValue);
		}
		const matchingVersions: SemanticVersion[] = [];
		for (const [
			possibleConfigValue,
			versionRequired,
		] of configValueToRequiredVersionMap.entries()) {
			assert(
				typeof possibleConfigValue == "object",
				0xbb9 ,
			);
			if (Object.entries(possibleConfigValue).some(([k, v]) => configValue[k] === v)) {
				matchingVersions.push(versionRequired);
			}
		}
		if (matchingVersions.length > 0) {
			return matchingVersions.sort((a, b) => compare(b, a))[0];
		}
		return undefined;
	};
}
```

### deltaManager: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/deltaManager.ts:1-34`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export function toDeltaManagerInternal(
	deltaManager: IDeltaManagerErased,
): IDeltaManager<ISequencedDocumentMessage, IDocumentMessage> {
	return deltaManager as unknown as IDeltaManager<ISequencedDocumentMessage, IDocumentMessage>;
}
export function toDeltaManagerErased(
	deltaManager: IDeltaManager<ISequencedDocumentMessage, IDocumentMessage>,
): IDeltaManagerErased {
	return deltaManager as unknown as IDeltaManagerErased;
}
```

### serviceClientBase: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientBase.ts:1-261`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export class DataStoreKindImplementation<T>
	extends ErasedTypeImplementation<DataStoreKind<T>>
	implements DataStoreKind<T>, IFluidDataStoreFactory
{
	public static guard<T>(
		value: T,
	): value is DataStoreKindImplementation<T extends DataStoreKind<infer T2> ? T2 : never> & T {
		return value instanceof DataStoreKindImplementation;
	}
	public static narrowGeneric<T>(
		value: T,
	): asserts value is DataStoreKindImplementation<
		T extends DataStoreKind<infer T2> ? T2 : never
	> &
		T {
		if (!DataStoreKindImplementation.guard(value)) {
			throw new Error("Invalid DataStoreKindImplementation");
		}
	}
	public readonly type: string;
	public readonly createDataStore?: (context: IFluidDataStoreContext) => {
		readonly runtime: IFluidDataStoreChannel;
	};
	public constructor(
		private readonly factory: Pick<
			DataStoreKindImplementation<T>,
			"type" | "instantiateDataStore" | "createDataStore"
		>,
	) {
		super();
		this.type = factory.type;
		if (factory.createDataStore !== undefined) {
			this.createDataStore = factory.createDataStore.bind(factory);
		}
	}
	public async instantiateDataStore(
		context: IFluidDataStoreContext,
		existing: boolean,
	): Promise<IFluidDataStoreChannel> {
		return this.factory.instantiateDataStore(context, existing);
	}
	public get IFluidDataStoreFactory(): IFluidDataStoreFactory {
		return this;
	}
	public async adapt(value: Promise<DataStoreKind>): Promise<DataStoreKind<T>> {
		const input = await value;
		if (input === this) {
			return this;
		}
		if (input.type === this.type) {
			throw new UsageError(`Conflicting DataStoreKinds with same type: ${this.type}`);
		}
		throw new UsageError(
			`Mismatched DataStoreKind type. Expected: ${this.type}, got: ${input.type}`,
		);
	}
}
export abstract class ServiceContainerBase<TData, TOptions = unknown>
	extends ErasedTypeImplementation<FluidContainerWithService<TData>>
	implements FluidContainerWithService<TData>
{
	private startedAttach = false;
	protected constructor(
		public readonly registry: Registry<Promise<DataStoreKind<TData>>>,
		public readonly options: TOptions,
		public readonly container: IContainer,
		public readonly data: TData,
		public id: string | undefined,
	) {
		super();
	}
	protected abstract createAttachRequest(): IRequest;
	protected getContainerId(): string {
		if (this.container.resolvedUrl === undefined) {
			throw new Error("Resolved URL unexpectedly missing!");
		}
		return this.container.resolvedUrl.id;
	}
	public async attach(): Promise<FluidContainerAttached<TData>> {
		if (this.id !== undefined) {
			throw new UsageError("Container already attached");
		}
		if (this.startedAttach) {
			throw new UsageError("Container attach already in progress");
		}
		assert(
			this.container.attachState === AttachState.Detached,
			0xd15 ,
		);
		this.startedAttach = true;
		await this.container.attach(this.createAttachRequest());
		assert(
			this.container.attachState === (AttachState.Attached as AttachState),
			0xd16 ,
		);
		this.id = this.getContainerId();
		return this as typeof this & { id: string };
	}
	public get audience(): IAudience {
		return this.container.audience;
	}
	public getRuntime(): IContainerRuntimeBase {
		interface IContainerWithRuntime extends IContainer {
			readonly runtime?: IContainerRuntimeBase;
		}
		const container = this.container as IContainerWithRuntime;
		if (container.runtime === undefined) {
			throw new Error(
				"Container does not expose a runtime: incompatible container implementation.",
			);
		}
		return container.runtime;
	}
	public close(): void {
		this.container.close();
	}
	public async createDataStore<T>(key: DataStoreKey<T>): Promise<T> {
		const kind = await lookupInRegistry(this.registry, key);
		DataStoreKindImplementation.narrowGeneric(kind);
		const containerRuntime = this.getRuntime();
		const context = containerRuntime.createDetachedDataStore([kind.type]);
		const channel = await kind.instantiateDataStore(context, false);
		const dataStore = await context.attachRuntime(kind, channel);
		const entryPoint = await dataStore.entryPoint.get();
		return entryPoint as T;
	}
}
export type Audience = IAudience;
export function getContainerAudience(container: FluidContainerAttached): Audience {
	ServiceContainerBase.narrow(container);
	return container.audience;
}
```

### serviceClientUtils: literal ordered algorithm

Source: `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientUtils.ts:1-239`. All declarations and executable statements follow, with imports/comments removed. Preserve branch predicates, field construction order, mutation-before-callback order and exception boundaries.

```typescript
export const rootDataStoreId = "root";
export function convertRegistry<T>(registry: DataStoreRegistry<T>): IFluidDataStoreRegistry {
	return {
		async get(name: string): Promise<FluidDataStoreRegistryEntry | undefined> {
			const dataStoreKind = await lookupInRegistry(registry, createBasicRegistryKey(name));
			DataStoreKindImplementation.narrowGeneric(dataStoreKind);
			return dataStoreKind;
		},
		get IFluidDataStoreRegistry(): IFluidDataStoreRegistry {
			return this;
		},
	};
}
export function normalizeRegistry<T>(
	input: DataStoreKind<T> | Registry<Promise<DataStoreKind<T>>>,
): Registry<Promise<DataStoreKind<T>>> {
	if (DataStoreKindImplementation.guard(input)) {
		return async () => input;
	}
	assert(typeof input === "function", 0xd17 );
	return input;
}
export interface ContainerRuntimeLoaderParams {
	context: IContainerContext;
	registry: IFluidDataStoreRegistry;
	provideEntryPoint: (runtime: IContainerRuntimeBase) => Promise<FluidObject>;
	existing: boolean;
	oldestSupportedClient: OldestSupportedClientVersion;
	newContainerRootType: string | undefined;
}
export type ContainerRuntimeLoader = (
	parameters: ContainerRuntimeLoaderParams,
) => Promise<IRuntime>;
export function makeCodeLoader<T>(
	registry: DataStoreRegistry<T>,
	oldestSupportedClient: OldestSupportedClientVersion,
	loadRuntime: ContainerRuntimeLoader,
	root?: DataStoreKind<T>,
): ICodeDetailsLoader {
	const fluidExport: IRuntimeFactory & IFluidCodeDetailsComparer = {
		async instantiateRuntime(
			context: IContainerContext,
			existing: boolean,
		): Promise<IRuntime> {
			const provideEntryPoint = async (
				entryPointRuntime: IContainerRuntimeBase,
			): Promise<T & FluidObject> => {
				const data = await entryPointRuntime.getAliasedDataStoreEntryPoint(rootDataStoreId);
				if (data === undefined) {
					throw new Error("Root data store missing!");
				}
				const rootDataStore = await data.get();
				return rootDataStore as T & FluidObject;
			};
			return loadRuntime({
				context,
				registry: convertRegistry(registry),
				provideEntryPoint,
				existing,
				oldestSupportedClient,
				newContainerRootType: root?.type,
			});
		},
		async satisfies(
			candidate: IFluidCodeDetails,
			constraint: IFluidCodeDetails,
		): Promise<boolean> {
			return true;
		},
		async compare(a: IFluidCodeDetails, b: IFluidCodeDetails): Promise<number | undefined> {
			return 0;
		},
		get IRuntimeFactory(): IRuntimeFactory {
			return fluidExport;
		},
		get IFluidCodeDetailsComparer(): IFluidCodeDetailsComparer {
			return fluidExport;
		},
	};
	return {
		load: async (details: IFluidCodeDetails): Promise<IFluidModuleWithDetails> => {
			return { module: { fluidExport }, details };
		},
	};
}
export interface ServiceContainerStatics<TOptions> {
	createDetached<T>(
		registry: DataStoreRegistry<T>,
		options: TOptions,
		root: DataStoreKind<T>,
	): Promise<FluidContainerWithService<T>>;
	load<T>(
		registry: DataStoreRegistry<T>,
		options: TOptions,
		id: string,
	): Promise<FluidContainerAttached<T>>;
}
export class ServiceClientImplementation<TOptions> implements ServiceClient {
	public constructor(
		private readonly options: TOptions,
		private readonly statics: ServiceContainerStatics<TOptions>,
	) {}
	public async createContainer<T>(
		root: DataStoreKey<T> | DataStoreKind<T>,
		registry?: Registry<Promise<DataStoreKind<T>>>,
	): Promise<FluidContainerWithService<T>> {
		if (registry === undefined) {
			DataStoreKindImplementation.narrowGeneric(root);
			return this.statics.createDetached(normalizeRegistry(root), this.options, root);
		} else {
			const result = await lookupInRegistry(registry, root);
			return this.statics.createDetached(registry, this.options, result);
		}
	}
	public async createAttachedContainer<T>(
		root: DataStoreKey<T> | DataStoreKind<T>,
		registry?: Registry<Promise<DataStoreKind<T>>>,
	): Promise<FluidContainerAttached<T>> {
		const container = await this.createContainer(root, registry);
		return container.attach();
	}
	public async loadContainer<T>(
		id: string,
		root: DataStoreKind<T> | Registry<Promise<DataStoreKind<T>>>,
	): Promise<FluidContainerAttached<T>> {
		return this.statics.load(normalizeRegistry(root), this.options, id);
	}
}
```

## 5. Invariants and asserts

Assertions terminate the operation; they are not successful empty results. Literal predicates occur at their ordered sites above:

- 0x19b: createResponseError status must differ from200. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/dataStoreHelpers.ts:1-183`
- 0x19c: partition base must not end `/`. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/objectstoragepartition.ts:1-38`
- 0x19d: remote handle absolutePath starts `/`. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/remoteFluidObjectHandle.ts:1-70`
- 0x8ff: found `.gcdata` is Blob with encoding `utf-8`. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`
- 0x5e0/0x9ab: unpacked nonself route starts `/` and has defined first-child component (empty string is not ruled out). `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/unpackUsedRoutes.ts:1-37`
- 0x900: compact numeric ID integer and>=0 (not Number.isSafeInteger). `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/utils.ts:1-109`
- 0xcb8: a version floor entry exists; 0xbb9: object-valued compatibility match entries are objects. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/compatibilityBase.ts:1-376`
- 0xd15/0xd16: container Detached before attach and Attached afterward; 0xd17: normalized registry is a function. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientBase.ts:1-261` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/serviceClientUtils.ts:1-239`

Other failures: invalid internal symbol conversion TypeError, missing package-path capability TypeError, non-fluid response becomes response exception, invalid subrequest/path throws, unexpected ITree entry throws, summary Handle conversion throws. Ordered code retains exact messages and propagation. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:1-264` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/remoteFluidObjectHandle.ts:1-70` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/requestParser.ts:1-104` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/objectstorageutils.ts:1-58` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631`

## 6. JS-semantics hazards

Use JS Object.entries order (integer index keys first), insertion-ordered Map/Set, shallow-copy semantics, strict equality/property existence and undefined omission. Numeric child attachment keys reorder before text keys; duplicate overwrite does not move Map/object insertion position. UTF-16 backward byte loop, malformed URI decoding, decoded subrequest joins and one-slash versus all-slash trimming must not be replaced with Foundation normalizers. Cache rejected handle promises; preserve async hook ordering and synchronous callback re-entry. `Number.isInteger` accepts represented integers outside safe range; don't silently substitute safe-integer validation for compact IDs. The plain response-exception object is not required to satisfy instanceof Error. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/summaryUtils.ts:1-631` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/requestParser.ts:1-104` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:1-264` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/dataStoreHelpers.ts:1-183` `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/utils.ts:1-109`

## 7. Test assets to reuse

- `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/summaryUtils.spec.ts:1-502` — tree/handle conversion, statistics, binary/string blobs, GC graph and UTF-8 sizing.
- `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/handles.spec.ts:1-163` — handle-symbol validation, comparison and pending-payload encoding.
- `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/requestParser.spec.ts:1-127` — queries, escaping, slash paths and subrequest boundaries.
- `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/dataStoreHelpers.spec.ts:1-38` — response/error round trips and query stripping.
- `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/runtimeFactoryHelper.spec.ts:1-61` — first-create versus existing-load hooks and order.
- `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/utils.spec.ts:1-84` — compact ID alphabet and boundary values.
- `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/test/compatibilityBase.spec.ts:1-557` — semver validation, config floors and override selection.

## 8. Open questions

None for the algorithms covered here. Driver-owned entry constructors and container-owned state machines remain separate package boundaries; their concrete fields used here are specified above.
