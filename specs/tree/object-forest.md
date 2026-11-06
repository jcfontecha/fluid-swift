# Object Forest — Fluid Framework 3.11.0

## 1. Role

ObjectForest is the straightforward MapTree-backed implementation of IEditableForest, useful as a differential reference for chunked storage. It uses the same delta and anchor protocols, not a different CRDT. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:83`

## 2. Surface used by other packages

buildForest/ObjectForest, allocation/navigation/clone, announced visitors, tree subscription cursors and forest chunking interface. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/index.ts:6`

## 3. Wire and persisted formats

None specific to object storage. Forest summaries use the common FieldSet/FieldBatch codec; MapTree object layout is in-memory only. Nodes have ordered fields and optional value. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:83` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:36`


## 4. Behavior

Forest owns synthetic roots MapTree and independent anchors. Clone deep-copies MapTree data and creates independent forest state. acquireVisitor enforces exclusive mutation; create copies cursor content into new root; attach moves entire source array into current field and removes source root; detach splices requested range into new detached root (if destination provided); destroy deletes exact root field. Empty fields are removed from parent map. Emits beforeChange before structural mutation; root creation emits afterRootFieldCreated after adding. Announced visitors are combined with forest/anchor traversal. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:133` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:180` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:369`

Cursor state includes cleared/current/freed, owning forest and inner cursor. Navigation into a path must use this forest's cursor. Stable relocation uses anchors; when a delta is about to mutate, current cursors must have been cleared. Preserve mode transitions and bounds rather than holding an Array index across mutations. Exact visitor/cursor implementation is extracted below. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:420` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:464`

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/object-forest/objectForest.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:1-655`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
interface MutableMapTree extends MapTree {
	readonly fields: Map<FieldKey, MutableMapTree[]>;
}
function getOrCreateField(mapTree: MutableMapTree, key: FieldKey): MutableMapTree[] {
	const field = mapTree.fields.get(key);
	if (field !== undefined) {
		return field;
	}
	const newField: MutableMapTree[] = [];
	mapTree.fields.set(key, newField);
	return newField;
}
export class ObjectForest implements IEditableForest, WithBreakable {
	private activeVisitor?: DeltaVisitor;
	public readonly currentCursors: Set<Cursor> = new Set();
	private readonly deltaVisitors: Set<() => AnnouncedVisitor> = new Set();
	readonly #events = createEmitter<ForestEvents>();
	public readonly events: Listenable<ForestEvents> = this.#events;
	readonly #roots: MutableMapTree;
	public get roots(): MapTree {
		this.breaker.use();
		return this.#roots;
	}
	public constructor(
		public readonly breaker: Breakable,
		public readonly schema: TreeStoredSchemaSubscription | undefined,
		public readonly anchors: AnchorSet = new AnchorSet(),
		public readonly additionalAsserts: boolean = false,
		roots?: MapTree,
	) {
		this.#roots =
			roots === undefined
				? {
						type: aboveRootPlaceholder,
						fields: new Map(),
					}
				: deepCopyMapTree(roots);
		if (additionalAsserts) {
			this.checkSchema();
		}
	}
	public get isEmpty(): boolean {
		this.breaker.use();
		return this.roots.fields.size === 0;
	}
	public clone(schema: TreeStoredSchemaSubscription, breaker?: Breakable): ObjectForest {
		this.breaker.use();
		return new ObjectForest(
			breaker ?? this.breaker,
			schema,
			undefined,
			this.additionalAsserts,
			this.roots,
		);
	}
	public chunkField(cursor: ITreeCursorSynchronous): TreeChunk[] {
		this.breaker.use();
		return chunkField(cursor, { idCompressor: undefined, policy: defaultChunkPolicy });
	}
	public forgetAnchor(anchor: Anchor): void {
		this.anchors.forget(anchor);
	}
	@breakingMethod
	public checkSchema(): void {
		const schema = this.schema;
		if (schema !== undefined) {
			const roots = new Set([...this.roots.fields.keys(), rootFieldKey]);
			for (const key of roots) {
				const documentRoot = this.roots.fields.get(key) ?? [];
				const fieldSchema: TreeFieldStoredSchema =
					key === rootFieldKey
						? schema.rootFieldSchema
						:
							{
								kind: FieldKinds.sequence.identifier,
								types: new Set(documentRoot.map((node) => node.type)),
								persistedMetadata: undefined,
							};
				isFieldInSchema(
					documentRoot,
					fieldSchema,
					{
						schema,
						policy: defaultSchemaPolicy,
					},
					throwOutOfSchema,
				);
			}
		}
	}
	public acquireVisitor(): DeltaVisitor {
		this.breaker.use();
		assert(
			this.activeVisitor === undefined,
			0x76c  ,
		);
		const cursor: Cursor = this.allocateCursor("acquireVisitor");
		cursor.setToAboveDetachedSequences();
		const preEdit = (): void => {
			this.#events.emit("beforeChange");
			assert(
				this.currentCursors.has(cursor),
				0x995  ,
			);
			if (this.currentCursors.size > 1) {
				const unexpectedSources = [...this.currentCursors].flatMap((c) =>
					c === cursor ? [] : (c.source ?? null),
				);
				throw new Error(
					`Found unexpected cursors when editing with the following annotations: ${JSON.stringify(
						unexpectedSources,
					)}`,
				);
			}
		};
		class Visitor implements DeltaVisitor {
			public constructor(private readonly forest: ObjectForest) {}
			public free(): void {
				cursor.free();
				assert(
					this.forest.activeVisitor !== undefined,
					0x76d  ,
				);
				this.forest.activeVisitor = undefined;
				if (this.forest.additionalAsserts) {
					this.forest.checkSchema();
				}
			}
			public destroy(detachedField: FieldKey, count: number): void {
				preEdit();
				const field = this.forest.#roots.fields.get(detachedField);
				assert(field !== undefined, 0xd28  );
				assert(field.length === count, 0xd29  );
				this.forest.delete(detachedField);
			}
			public create(content: readonly ITreeCursorSynchronous[], destination: FieldKey): void {
				preEdit();
				assert(
					!this.forest.#roots.fields.has(destination),
					0xd2a  ,
				);
				this.forest.add(content, destination);
				this.forest.#events.emit("afterRootFieldCreated", destination);
			}
			public attach(source: FieldKey, count: number, destination: PlaceIndex): void {
				preEdit();
				this.attachEdit(source, count, destination);
			}
			public detach(source: Range, destination: FieldKey, id: DeltaDetachedNodeId): void {
				preEdit();
				this.detachEdit(source, destination);
			}
			private attachEdit(source: FieldKey, count: number, destination: PlaceIndex): void {
				assertNonNegativeSafeInteger(count);
				const [parent, key] = cursor.getParent();
				assert(
					parent !== this.forest.roots || key !== source,
					0xd2b  ,
				);
				const sourceField = this.forest.#roots.fields.get(source);
				assert(sourceField !== undefined, 0xd2c  );
				assert(
					sourceField.length === count,
					0xd2d  ,
				);
				const existingDestinationField = parent.fields.get(key) ?? [];
				assert(
					destination <= existingDestinationField.length,
					0xd2e  ,
				);
				assertValidIndex(destination, existingDestinationField, true);
				const currentField = getOrCreateField(parent, key);
				currentField.splice(destination, 0, ...sourceField);
				this.forest.delete(source);
			}
			private detachEdit(source: Range, destination: FieldKey | undefined): void {
				const [parent, key] = cursor.getParent();
				assert(
					destination === undefined || parent !== this.forest.roots || key !== destination,
					0xd2f  ,
				);
				const currentField = parent.fields.get(key) ?? [];
				assert(source.start <= source.end, 0xd30  );
				assert(
					source.end <= currentField.length,
					0xd31  ,
				);
				assertValidRange(source, currentField);
				if (destination !== undefined) {
					assert(
						!this.forest.#roots.fields.has(destination),
						0xd32  ,
					);
				}
				const content = currentField.splice(source.start, source.end - source.start);
				if (destination !== undefined) {
					this.forest.addFieldAsDetached(content, destination);
				}
				if (currentField.length === 0) {
					parent.fields.delete(key);
				}
			}
			public enterNode(index: number): void {
				cursor.enterNode(index);
			}
			public exitNode(index: number): void {
				cursor.exitNode();
			}
			public enterField(key: FieldKey): void {
				cursor.enterField(key);
			}
			public exitField(key: FieldKey): void {
				cursor.exitField();
			}
		}
		const forestVisitor = new Visitor(this);
		const announcedVisitors: AnnouncedVisitor[] = [];
		for (const getVisitor of this.deltaVisitors) {
			announcedVisitors.push(getVisitor());
		}
		const visitor = combineVisitors([
			makeBreakingVisitor(forestVisitor, this.breaker),
			...announcedVisitors,
		]);
		this.activeVisitor = visitor;
		return visitor;
	}
	public registerAnnouncedVisitor(visitor: () => AnnouncedVisitor): void {
		this.deltaVisitors.add(visitor);
	}
	public deregisterAnnouncedVisitor(visitor: () => AnnouncedVisitor): void {
		this.deltaVisitors.delete(visitor);
	}
	private nextRange = 0;
	public newDetachedField(): DetachedField {
		const range: DetachedField = brand(String(this.nextRange));
		this.nextRange += 1;
		return range;
	}
	private add(nodes: Iterable<ITreeCursor>, key: FieldKey): void {
		const field = Array.from(nodes, mapTreeFromCursor) as MutableMapTree[];
		this.addFieldAsDetached(field, key);
	}
	private addFieldAsDetached(field: MutableMapTree[], key: FieldKey): void {
		assert(!this.roots.fields.has(key), 0x370  );
		if (field.length > 0) {
			this.#roots.fields.set(key, field);
		}
	}
	private delete(field: FieldKey): void {
		this.#roots.fields.delete(field);
	}
	public allocateCursor(source?: string): Cursor {
		this.breaker.use();
		return new Cursor(this, source);
	}
	public tryMoveCursorToNode(
		destination: Anchor,
		cursorToMove: ITreeSubscriptionCursor,
	): TreeNavigationResult {
		this.breaker.use();
		const path = this.anchors.locate(destination);
		if (path === undefined) {
			return TreeNavigationResult.NotFound;
		}
		this.moveCursorToPath(path, cursorToMove);
		return TreeNavigationResult.Ok;
	}
	public tryMoveCursorToField(
		destination: FieldAnchor,
		cursorToMove: ITreeSubscriptionCursor,
	): TreeNavigationResult {
		this.breaker.use();
		if (destination.parent === undefined) {
			this.moveCursorToPath(undefined, cursorToMove);
		} else {
			const result = this.tryMoveCursorToNode(destination.parent, cursorToMove);
			if (result !== TreeNavigationResult.Ok) {
				return result;
			}
		}
		cursorToMove.enterField(destination.fieldKey);
		return TreeNavigationResult.Ok;
	}
	public moveCursorToPath(
		destination: UpPath | undefined,
		cursorToMove: ITreeSubscriptionCursor,
	): void {
		this.breaker.use();
		assert(
			cursorToMove instanceof Cursor,
			0x337  ,
		);
		assert(
			cursorToMove.forest === this,
			0x338  ,
		);
		const indexStack: number[] = [];
		const keyStack: FieldKey[] = [];
		let path: UpPath | undefined = destination;
		while (path !== undefined) {
			indexStack.push(path.parentIndex);
			keyStack.push(path.parentField);
			path = path.parent;
		}
		cursorToMove.setToAboveDetachedSequences();
		while (keyStack.length > 0) {
			cursorToMove.enterField(keyStack.pop()!);
			cursorToMove.enterNode(indexStack.pop()!);
		}
		return;
	}
	public getCursorAboveDetachedFields(): ITreeCursorSynchronous {
		this.breaker.use();
		return cursorForMapTreeNode(this.roots);
	}
}
class Cursor extends SynchronousCursor implements ITreeSubscriptionCursor {
	public state: ITreeSubscriptionCursorState;
	public constructor(
		public readonly forest: ObjectForest,
		public readonly source: string | undefined,
		private innerCursor?: CursorWithNode<MutableMapTree>,
	) {
		super();
		if (innerCursor === undefined) {
			this.state = ITreeSubscriptionCursorState.Cleared;
		} else {
			this.state = ITreeSubscriptionCursorState.Current;
			this.forest.currentCursors.add(this);
		}
	}
	public buildFieldAnchor(): FieldAnchor {
		const path = this.getFieldPath();
		const anchor =
			path.parent === undefined ? undefined : this.forest.anchors.track(path.parent);
		return { parent: anchor, fieldKey: path.field };
	}
	public getFieldPath(prefix?: PathRootPrefix): FieldUpPath {
		assert(this.innerCursor !== undefined, 0x45f  );
		return this.innerCursor.getFieldPath(prefix);
	}
	public get mode(): CursorLocationType {
		assert(this.innerCursor !== undefined, 0x42e  );
		return this.innerCursor.mode;
	}
	public nextField(): boolean {
		assert(this.innerCursor !== undefined, 0x42f  );
		return this.innerCursor.nextField();
	}
	public exitField(): void {
		assert(this.innerCursor !== undefined, 0x430  );
		return this.innerCursor.exitField();
	}
	public override skipPendingFields(): boolean {
		assert(this.innerCursor !== undefined, 0x431  );
		return this.innerCursor.skipPendingFields();
	}
	public getFieldKey(): FieldKey {
		assert(this.innerCursor !== undefined, 0x432  );
		return this.innerCursor.getFieldKey();
	}
	public getFieldLength(): number {
		assert(this.innerCursor !== undefined, 0x433  );
		return this.innerCursor.getFieldLength();
	}
	public firstNode(): boolean {
		assert(this.innerCursor !== undefined, 0x434  );
		return this.innerCursor.firstNode();
	}
	public enterNode(childIndex: number): void {
		assert(this.innerCursor !== undefined, 0x435  );
		return this.innerCursor.enterNode(childIndex);
	}
	public getPath(prefix?: PathRootPrefix): UpPath {
		assert(this.innerCursor !== undefined, 0x436  );
		return this.innerCursor.getPath(prefix) ?? fail(0xb27  );
	}
	public get fieldIndex(): number {
		assert(this.innerCursor !== undefined, 0x437  );
		return this.innerCursor.fieldIndex;
	}
	public get chunkStart(): number {
		assert(this.innerCursor !== undefined, 0x438  );
		return this.innerCursor.chunkStart;
	}
	public get chunkLength(): number {
		assert(this.innerCursor !== undefined, 0x439  );
		return this.innerCursor.chunkLength;
	}
	public seekNodes(offset: number): boolean {
		assert(this.innerCursor !== undefined, 0x43a  );
		return this.innerCursor.seekNodes(offset);
	}
	public nextNode(): boolean {
		assert(this.innerCursor !== undefined, 0x43b  );
		return this.innerCursor.nextNode();
	}
	public exitNode(): void {
		assert(this.innerCursor !== undefined, 0x43c  );
		return this.innerCursor.exitNode();
	}
	public firstField(): boolean {
		assert(this.innerCursor !== undefined, 0x43d  );
		return this.innerCursor.firstField();
	}
	public enterField(key: FieldKey): void {
		assert(this.innerCursor !== undefined, 0x43e  );
		return this.innerCursor.enterField(key);
	}
	public get type(): TreeNodeSchemaIdentifier {
		assert(this.innerCursor !== undefined, 0x43f  );
		return this.innerCursor.type;
	}
	public get value(): Value {
		assert(this.innerCursor !== undefined, 0x440  );
		return this.innerCursor.value;
	}
	public clear(): void {
		assert(
			this.state !== ITreeSubscriptionCursorState.Freed,
			0x33b  ,
		);
		this.state = ITreeSubscriptionCursorState.Cleared;
		this.innerCursor = undefined;
		this.forest.currentCursors.delete(this);
	}
	public setToAboveDetachedSequences(): void {
		assert(
			this.state !== ITreeSubscriptionCursorState.Freed,
			0x33c  ,
		);
		this.clear();
		this.state = ITreeSubscriptionCursorState.Current;
		this.innerCursor = cursorForMapTreeNode(
			this.forest.roots,
		) as CursorWithNode<MutableMapTree>;
		this.forest.currentCursors.add(this);
	}
	public getNode(): MutableMapTree {
		assert(this.innerCursor !== undefined, 0x33e  );
		return this.innerCursor.getNode();
	}
	public getParent(): [MutableMapTree, FieldKey] {
		assert(this.innerCursor !== undefined, 0x441  );
		const key = this.innerCursor.getFieldKey();
		this.innerCursor.exitField();
		const node = this.innerCursor.getNode();
		this.innerCursor.enterField(key);
		return [node, key];
	}
	public fork(source?: string): ITreeSubscriptionCursor {
		assert(this.innerCursor !== undefined, 0x460  );
		return new Cursor(this.forest, source ?? `fork: ${this.source}`, this.innerCursor.fork());
	}
	public free(): void {
		assert(
			this.state !== ITreeSubscriptionCursorState.Freed,
			0x33f  ,
		);
		this.forest.currentCursors.delete(this);
		this.state = ITreeSubscriptionCursorState.Freed;
	}
	public buildAnchor(): Anchor {
		assert(
			this.state === ITreeSubscriptionCursorState.Current,
			0x37a  ,
		);
		return this.forest.anchors.track(this.getPath());
	}
}
export function buildForest(
	breaker: Breakable,
	schema?: TreeStoredSchemaSubscription,
	anchors?: AnchorSet,
	additionalAsserts: boolean = false,
): ObjectForest {
	return new ObjectForest(breaker, schema, anchors, additionalAsserts);
}
```

### Decision procedure: `feature-libraries/mapTreeCursor.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/mapTreeCursor.ts:1-182`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface MapTreeNodeViewGeneric<TNode> extends NodeData {
	readonly fields: MinimalFieldMap<MapTreeFieldViewGeneric<TNode>>;
}
export interface MinimalFieldMap<TField> {
	[Symbol.iterator]: () => Iterator<[FieldKey, TField]>;
	get: (key: FieldKey) => TField | undefined;
}
export interface MapTreeFieldViewGeneric<TNode> {
	readonly [Symbol.iterator]: () => Iterator<TNode>;
	readonly length: number;
}
export interface MinimalMapTreeNodeView
	extends MapTreeNodeViewGeneric<MinimalMapTreeNodeView> {}
{
	type _check1 = requireAssignableTo<MapTree, MinimalMapTreeNodeView>;
	type _check2 = requireAssignableTo<MapTree, MapTreeNodeViewGeneric<MapTree>>;
}
export function cursorForMapTreeNode<T extends MapTreeNodeViewGeneric<T>>(
	root: T,
): CursorWithNode<T> {
	const adapterTyped = adapter as CursorAdapter<MapTreeNodeViewGeneric<T>> as CursorAdapter<T>;
	return stackTreeNodeCursor(adapterTyped, root);
}
export function mapTreeWithField(
	children: ExclusiveMapTree[],
	key = rootFieldKey,
	type = aboveRootPlaceholder,
): ExclusiveMapTree {
	return {
		type,
		fields: mapTreeFieldsWithField(children, key),
	};
}
export function mapTreeFieldsWithField<T extends readonly unknown[]>(
	children: T,
	key: FieldKey,
): Map<FieldKey, T> {
	return new Map(children.length === 0 ? [] : [[key, children]]);
}
export function cursorForMapTreeField<T extends MapTreeNodeViewGeneric<T>>(
	root: readonly T[],
	detachedField: DetachedField = rootField,
): CursorWithNode<T> {
	const key = detachedFieldAsKey(detachedField);
	const adapterTyped = adapter as unknown as CursorAdapter<T>;
	const dummyRoot: MapTreeNodeViewGeneric<T> = {
		type: aboveRootPlaceholder,
		fields: mapTreeFieldsWithField(root, key),
	};
	return stackTreeFieldCursor(adapterTyped, dummyRoot as T, detachedField);
}
const adapter: CursorAdapter<MinimalMapTreeNodeView> = {
	value: (node) => node.value,
	type: (node) => node.type,
	keysFromNode: (node) => Array.from(node.fields, ([key, field]) => key),
	getFieldFromNode: (node, key): Field<MinimalMapTreeNodeView> => {
		const field = node.fields.get(key) as
			| MinimalMapTreeNodeView[]
			| Iterable<MinimalMapTreeNodeView>
			| undefined;
		if (field === undefined) {
			return [];
		}
		if (Array.isArray(field)) {
			return field as readonly MinimalMapTreeNodeView[];
		}
		return [...field] as readonly MinimalMapTreeNodeView[];
	},
};
export function mapTreeFromCursor(cursor: ITreeCursor): ExclusiveMapTree {
	assert(cursor.mode === CursorLocationType.Nodes, 0x3b7  );
	const fields: Map<FieldKey, ExclusiveMapTree[]> = new Map();
	for (let inField = cursor.firstField(); inField; inField = cursor.nextField()) {
		const field: ExclusiveMapTree[] = mapCursorField(cursor, mapTreeFromCursor);
		fields.set(cursor.getFieldKey(), field);
	}
	const node: ExclusiveMapTree = {
		type: cursor.type,
		value: cursor.value,
		fields,
	};
	return node;
}
export function mapTreeFieldFromCursor(cursor: ITreeCursor): ExclusiveMapTree[] {
	assert(cursor.mode === CursorLocationType.Fields, 0xa03  );
	return mapCursorField(cursor, mapTreeFromCursor);
}
```

## 5. Invariants and asserts

Foreign cursor type/owner rejected 0x337/0x338. Root field must not already exist 0x370. Cursor methods reject missing current innerCursor (0x42e and adjacent). Attach/detach/destroy checks deliberately mirror chunked forest, including new empty destination and entire-source consumption. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:420` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:374` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:194`

## 6. JS-semantics hazards

MapTree identity and array splice order matter to traversal; omitted empty field is not a persisted empty entry. JS arrays splice before adding detached root and key iteration follows Map insertion order. Cursor lifetime is explicit despite GC. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:194` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/object-forest/objectForest.ts:369`

## 7. Test assets to reuse

Use common forest suite against both implementations, plus object forest tests. A Swift chunked forest should produce the same cursor and anchor observations as this implementation for each delta. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/objectForest.spec.ts:1`

## 8. Open questions

None.

