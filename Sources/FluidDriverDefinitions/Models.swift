import FluidJS

/// ICapabilities: retains the entire received object as its immutable JSON backing store.
public struct ICapabilities: DriverJSONValue {
    public let json: JSONValue
    public let interactive: Bool
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.interactive = try decodeBool(json.member("interactive"))
        self.json = json
    }
}

/// IClientDetails: retains the entire received object as its immutable JSON backing store.
public struct IClientDetails: DriverJSONValue {
    public let json: JSONValue
    public let capabilities: ICapabilities
    public let type: JSString?
    public let environment: JSString?
    public let device: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.capabilities = try ICapabilities(json: json.member("capabilities"))
        self.type = try object["type"].map { value in try value.asString() }
        self.environment = try object["environment"].map { value in try value.asString() }
        self.device = try object["device"].map { value in try value.asString() }
        self.json = json
    }
}

/// IUser: retains the entire received object as its immutable JSON backing store.
public struct IUser: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.id = try json.member("id").asString()
        self.json = json
    }
}

/// IClient: retains the entire received object as its immutable JSON backing store.
public struct IClient: DriverJSONValue {
    public let json: JSONValue
    public let mode: ConnectionMode
    public let details: IClientDetails
    public let permission: [JSString]
    public let user: IUser
    public let scopes: [JSString]
    public let timestamp: Double?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.mode = try ConnectionMode(json: json.member("mode"))
        self.details = try IClientDetails(json: json.member("details"))
        self.permission = try json.member("permission").asArray().map { value in try value.asString() }
        self.user = try IUser(json: json.member("user"))
        self.scopes = try json.member("scopes").asArray().map { value in try value.asString() }
        self.timestamp = try object["timestamp"].map { value in try value.asNumber() }
        self.json = json
    }
}

/// ISequencedClient: retains the entire received object as its immutable JSON backing store.
public struct ISequencedClient: DriverJSONValue {
    public let json: JSONValue
    public let client: IClient
    public let sequenceNumber: Int
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.client = try IClient(json: json.member("client"))
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.json = json
    }
}

/// ISignalClient: retains the entire received object as its immutable JSON backing store.
public struct ISignalClient: DriverJSONValue {
    public let json: JSONValue
    public let clientId: JSString
    public let client: IClient
    public let clientConnectionNumber: Int?
    public let referenceSequenceNumber: Int?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.clientId = try json.member("clientId").asString()
        self.client = try IClient(json: json.member("client"))
        self.clientConnectionNumber = try object["clientConnectionNumber"].map { value in try decodeInt(value) }
        self.referenceSequenceNumber = try object["referenceSequenceNumber"].map { value in try decodeInt(value) }
        self.json = json
    }
}

/// IClientJoin: retains the entire received object as its immutable JSON backing store.
public struct IClientJoin: DriverJSONValue {
    public let json: JSONValue
    public let clientId: JSString
    public let detail: IClient
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.clientId = try json.member("clientId").asString()
        self.detail = try IClient(json: json.member("detail"))
        self.json = json
    }
}

/// IClientConfiguration: retains the entire received object as its immutable JSON backing store.
public struct IClientConfiguration: DriverJSONValue {
    public let json: JSONValue
    public let maxMessageSize: Double
    public let blockSize: Double
    public let noopTimeFrequency: Double?
    public let noopCountFrequency: Double?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.maxMessageSize = try json.member("maxMessageSize").asNumber()
        self.blockSize = try json.member("blockSize").asNumber()
        self.noopTimeFrequency = try object["noopTimeFrequency"].map { value in try value.asNumber() }
        self.noopCountFrequency = try object["noopCountFrequency"].map { value in try value.asNumber() }
        self.json = json
    }
}

/// IProposal: retains the entire received object as its immutable JSON backing store.
public struct IProposal: DriverJSONValue {
    public let json: JSONValue
    public let key: JSString
    public let value: JSONValue?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.key = try json.member("key").asString()
        self.value = object["value"]
        self.json = json
    }
}

/// ISequencedProposal: retains the entire received object as its immutable JSON backing store.
public struct ISequencedProposal: DriverJSONValue {
    public let json: JSONValue
    public let key: JSString
    public let value: JSONValue?
    public let sequenceNumber: Int
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.key = try json.member("key").asString()
        self.value = object["value"]
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.json = json
    }
}

/// IApprovedProposal: retains the entire received object as its immutable JSON backing store.
public struct IApprovedProposal: DriverJSONValue {
    public let json: JSONValue
    public let key: JSString
    public let value: JSONValue?
    public let sequenceNumber: Int
    public let approvalSequenceNumber: Int
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.key = try json.member("key").asString()
        self.value = object["value"]
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.approvalSequenceNumber = try decodeInt(json.member("approvalSequenceNumber"))
        self.json = json
    }
}

/// ICommittedProposal: retains the entire received object as its immutable JSON backing store.
public struct ICommittedProposal: DriverJSONValue {
    public let json: JSONValue
    public let key: JSString
    public let value: JSONValue?
    public let sequenceNumber: Int
    public let approvalSequenceNumber: Int
    public let commitSequenceNumber: Int
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.key = try json.member("key").asString()
        self.value = object["value"]
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.approvalSequenceNumber = try decodeInt(json.member("approvalSequenceNumber"))
        self.commitSequenceNumber = try decodeInt(json.member("commitSequenceNumber"))
        self.json = json
    }
}

/// IProcessMessageResult: retains the entire received object as its immutable JSON backing store.
public struct IProcessMessageResult: DriverJSONValue {
    public let json: JSONValue
    public let immediateNoOp: Bool?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.immediateNoOp = try object["immediateNoOp"].map { value in try decodeBool(value) }
        self.json = json
    }
}

/// ITrace: retains the entire received object as its immutable JSON backing store.
public struct ITrace: DriverJSONValue {
    public let json: JSONValue
    public let service: JSString
    public let action: JSString
    public let timestamp: Double
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.service = try json.member("service").asString()
        self.action = try json.member("action").asString()
        self.timestamp = try json.member("timestamp").asNumber()
        self.json = json
    }
}

/// IBranchOrigin: retains the entire received object as its immutable JSON backing store.
public struct IBranchOrigin: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString
    public let sequenceNumber: Int
    public let minimumSequenceNumber: Int
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.id = try json.member("id").asString()
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.minimumSequenceNumber = try decodeInt(json.member("minimumSequenceNumber"))
        self.json = json
    }
}

/// INackContent: retains the entire received object as its immutable JSON backing store.
public struct INackContent: DriverJSONValue {
    public let json: JSONValue
    public let code: Double
    public let type: NackErrorType
    public let message: JSString
    public let retryAfter: Double?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.code = try json.member("code").asNumber()
        self.type = try NackErrorType(json: json.member("type"))
        self.message = try json.member("message").asString()
        self.retryAfter = try object["retryAfter"].map { value in try value.asNumber() }
        self.json = json
    }
}

/// INack: retains the entire received object as its immutable JSON backing store.
public struct INack: DriverJSONValue {
    public let json: JSONValue
    public let operation: IDocumentMessage?
    public let sequenceNumber: Int
    public let content: INackContent
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.operation = try object["operation"].map { value in try IDocumentMessage(json: value) }
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.content = try INackContent(json: json.member("content"))
        self.json = json
    }
}

/// IUploadedSummaryDetails: retains the entire received object as its immutable JSON backing store.
public struct IUploadedSummaryDetails: DriverJSONValue {
    public let json: JSONValue
    public let includesProtocolTree: Bool?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.includesProtocolTree = try object["includesProtocolTree"].map { value in try decodeBool(value) }
        self.json = json
    }
}

/// ISummaryContent: retains the entire received object as its immutable JSON backing store.
public struct ISummaryContent: DriverJSONValue {
    public let json: JSONValue
    public let handle: JSString
    public let message: JSString
    public let parents: [JSString]
    public let head: JSString
    public let details: IUploadedSummaryDetails?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.handle = try json.member("handle").asString()
        self.message = try json.member("message").asString()
        self.parents = try json.member("parents").asArray().map { value in try value.asString() }
        self.head = try json.member("head").asString()
        self.details = try object["details"].map { value in try IUploadedSummaryDetails(json: value) }
        self.json = json
    }
}

/// IServerError: retains the entire received object as its immutable JSON backing store.
public struct IServerError: DriverJSONValue {
    public let json: JSONValue
    public let errorMessage: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.errorMessage = try json.member("errorMessage").asString()
        self.json = json
    }
}

/// ISummaryProposal: retains the entire received object as its immutable JSON backing store.
public struct ISummaryProposal: DriverJSONValue {
    public let json: JSONValue
    public let summarySequenceNumber: Int
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.summarySequenceNumber = try decodeInt(json.member("summarySequenceNumber"))
        self.json = json
    }
}

/// ISummaryAck: retains the entire received object as its immutable JSON backing store.
public struct ISummaryAck: DriverJSONValue {
    public let json: JSONValue
    public let handle: JSString
    public let summaryProposal: ISummaryProposal
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.handle = try json.member("handle").asString()
        self.summaryProposal = try ISummaryProposal(json: json.member("summaryProposal"))
        self.json = json
    }
}

/// ISummaryNack: retains the entire received object as its immutable JSON backing store.
public struct ISummaryNack: DriverJSONValue {
    public let json: JSONValue
    public let summaryProposal: ISummaryProposal
    public let code: Double?
    public let message: JSString?
    public let retryAfter: Double?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.summaryProposal = try ISummaryProposal(json: json.member("summaryProposal"))
        self.code = try object["code"].map { value in try value.asNumber() }
        self.message = try object["message"].map { value in try value.asString() }
        self.retryAfter = try object["retryAfter"].map { value in try value.asNumber() }
        self.json = json
    }
}

/// ITokenClaims: retains the entire received object as its immutable JSON backing store.
public struct ITokenClaims: DriverJSONValue {
    public let json: JSONValue
    public let documentId: JSString
    public let scopes: [JSString]
    public let tenantId: JSString
    public let user: IUser
    public let iat: Double
    public let exp: Double
    public let ver: JSString
    public let jti: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.documentId = try json.member("documentId").asString()
        self.scopes = try json.member("scopes").asArray().map { value in try value.asString() }
        self.tenantId = try json.member("tenantId").asString()
        self.user = try IUser(json: json.member("user"))
        self.iat = try json.member("iat").asNumber()
        self.exp = try json.member("exp").asNumber()
        self.ver = try json.member("ver").asString()
        self.jti = try object["jti"].map { value in try value.asString() }
        self.json = json
    }
}

/// IConnect: retains the entire received object as its immutable JSON backing store.
public struct IConnect: DriverJSONValue {
    public let json: JSONValue
    public let tenantId: JSString
    public let id: JSString
    public let token: JSString?
    public let client: IClient
    public let versions: [JSString]
    public let driverVersion: JSString?
    public let mode: ConnectionMode
    public let nonce: JSString?
    public let epoch: JSString?
    public let supportedFeatures: JSObject<JSONValue>?
    public let relayUserAgent: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.tenantId = try json.member("tenantId").asString()
        self.id = try json.member("id").asString()
        self.token = try decodeNullableString(json.member("token"))
        self.client = try IClient(json: json.member("client"))
        self.versions = try json.member("versions").asArray().map { value in try value.asString() }
        self.driverVersion = try object["driverVersion"].map { value in try value.asString() }
        self.mode = try ConnectionMode(json: json.member("mode"))
        self.nonce = try object["nonce"].map { value in try value.asString() }
        self.epoch = try object["epoch"].map { value in try value.asString() }
        self.supportedFeatures = try object["supportedFeatures"].map { value in try decodeMap(value) { value in value } }
        self.relayUserAgent = try object["relayUserAgent"].map { value in try value.asString() }
        self.json = json
    }
}

/// IConnected: retains the entire received object as its immutable JSON backing store.
public struct IConnected: DriverJSONValue {
    public let json: JSONValue
    public let claims: ITokenClaims
    public let clientId: JSString
    public let existing: Bool
    public let maxMessageSize: Double
    public let initialMessages: [ISequencedDocumentMessage]
    public let initialSignals: [ISignalMessage]
    public let initialClients: [ISignalClient]
    public let version: JSString
    public let supportedVersions: [JSString]
    public let serviceConfiguration: IClientConfiguration
    public let mode: ConnectionMode
    public let nonce: JSString?
    public let checkpointSequenceNumber: Int?
    public let epoch: JSString?
    public let supportedFeatures: JSObject<JSONValue>?
    public let timestamp: Double?
    public let relayServiceAgent: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.claims = try ITokenClaims(json: json.member("claims"))
        self.clientId = try json.member("clientId").asString()
        self.existing = try decodeBool(json.member("existing"))
        self.maxMessageSize = try json.member("maxMessageSize").asNumber()
        self.initialMessages = try json.member("initialMessages").asArray().map { value in try ISequencedDocumentMessage(json: value) }
        self.initialSignals = try json.member("initialSignals").asArray().map { value in try ISignalMessage(json: value) }
        self.initialClients = try json.member("initialClients").asArray().map { value in try ISignalClient(json: value) }
        self.version = try json.member("version").asString()
        self.supportedVersions = try json.member("supportedVersions").asArray().map { value in try value.asString() }
        self.serviceConfiguration = try IClientConfiguration(json: json.member("serviceConfiguration"))
        self.mode = try ConnectionMode(json: json.member("mode"))
        self.nonce = try object["nonce"].map { value in try value.asString() }
        self.checkpointSequenceNumber = try object["checkpointSequenceNumber"].map { value in try decodeInt(value) }
        self.epoch = try object["epoch"].map { value in try value.asString() }
        self.supportedFeatures = try object["supportedFeatures"].map { value in try decodeMap(value) { value in value } }
        self.timestamp = try object["timestamp"].map { value in try value.asNumber() }
        self.relayServiceAgent = try object["relayServiceAgent"].map { value in try value.asString() }
        self.json = json
    }
}

/// IDocumentAttributes: retains the entire received object as its immutable JSON backing store.
public struct IDocumentAttributes: DriverJSONValue {
    public let json: JSONValue
    public let sequenceNumber: Int
    public let minimumSequenceNumber: Int
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.minimumSequenceNumber = try decodeInt(json.member("minimumSequenceNumber"))
        self.json = json
    }
}

/// IBlob: retains the entire received object as its immutable JSON backing store.
public struct IBlob: DriverJSONValue {
    public let json: JSONValue
    public let contents: JSString
    public let encoding: BlobEncoding
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.contents = try json.member("contents").asString()
        self.encoding = try BlobEncoding(json: json.member("encoding"))
        self.json = json
    }
}

/// IAttachment: retains the entire received object as its immutable JSON backing store.
public struct IAttachment: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.id = try json.member("id").asString()
        self.json = json
    }
}

/// ICreateBlobResponse: retains the entire received object as its immutable JSON backing store.
public struct ICreateBlobResponse: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.id = try json.member("id").asString()
        self.json = json
    }
}

/// ITree: retains the entire received object as its immutable JSON backing store.
public struct ITree: DriverJSONValue {
    public let json: JSONValue
    public let entries: [ITreeEntry]
    public let id: JSString?
    public let unreferenced: Bool?
    public let groupId: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.entries = try json.member("entries").asArray().map { value in try ITreeEntry(json: value) }
        self.id = try object["id"].map { value in try value.asString() }
        self.unreferenced = try object["unreferenced"].map { value in try decodeTrue(value) }
        self.groupId = try object["groupId"].map { value in try value.asString() }
        self.json = json
    }
}

/// ISnapshotTree: retains the entire received object as its immutable JSON backing store.
public struct ISnapshotTree: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString?
    public let blobs: JSObject<JSString>
    public let trees: JSObject<ISnapshotTree>
    public let unreferenced: Bool?
    public let groupId: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.id = try object["id"].map { value in try value.asString() }
        self.blobs = try decodeMap(json.member("blobs")) { value in try value.asString() }
        self.trees = try decodeMap(json.member("trees")) { value in try ISnapshotTree(json: value) }
        self.unreferenced = try object["unreferenced"].map { value in try decodeTrue(value) }
        self.groupId = try object["groupId"].map { value in try value.asString() }
        self.json = json
    }
}

/// ISnapshotTreeEx: retains the entire received object as its immutable JSON backing store.
public struct ISnapshotTreeEx: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString
    public let blobs: JSObject<JSString>
    public let trees: JSObject<ISnapshotTreeEx>
    public let unreferenced: Bool?
    public let groupId: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.id = try json.member("id").asString()
        self.blobs = try decodeMap(json.member("blobs")) { value in try value.asString() }
        self.trees = try decodeMap(json.member("trees")) { value in try ISnapshotTreeEx(json: value) }
        self.unreferenced = try object["unreferenced"].map { value in try decodeTrue(value) }
        self.groupId = try object["groupId"].map { value in try value.asString() }
        self.json = json
    }
}

/// IVersion: retains the entire received object as its immutable JSON backing store.
public struct IVersion: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString
    /// Optional in practice: ODSP returns `{ id, treeId: undefined! }` (odspDocumentStorageManager.ts).
    public let treeId: JSString?
    public let date: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.id = try json.member("id").asString()
        self.treeId = try object["treeId"].map { value in try value.asString() }
        self.date = try object["date"].map { value in try value.asString() }
        self.json = json
    }
}

/// ISummaryHandle: retains the entire received object as its immutable JSON backing store.
public struct ISummaryHandle: DriverJSONValue {
    public let json: JSONValue
    public let type: Int
    public let handleType: SummaryTypeNoHandle
    public let handle: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.type = try decodeLiteral(json.member("type"), 3)
        self.handleType = try SummaryTypeNoHandle(json: json.member("handleType"))
        self.handle = try json.member("handle").asString()
        self.json = json
    }
}

/// ISummaryBlob: retains the entire received object as its immutable JSON backing store.
public struct ISummaryBlob: DriverJSONValue {
    public let json: JSONValue
    public let type: Int
    public let content: SummaryBlobContent
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.type = try decodeLiteral(json.member("type"), 2)
        self.content = try SummaryBlobContent(json: json.member("content"))
        self.json = json
    }
}

/// ISummaryAttachment: retains the entire received object as its immutable JSON backing store.
public struct ISummaryAttachment: DriverJSONValue {
    public let json: JSONValue
    public let type: Int
    public let id: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.type = try decodeLiteral(json.member("type"), 4)
        self.id = try json.member("id").asString()
        self.json = json
    }
}

/// ISummaryTree: retains the entire received object as its immutable JSON backing store.
public struct ISummaryTree: DriverJSONValue {
    public let json: JSONValue
    public let type: Int
    public let tree: JSObject<SummaryObject>
    public let unreferenced: Bool?
    public let groupId: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.type = try decodeLiteral(json.member("type"), 1)
        self.tree = try decodeMap(json.member("tree")) { value in try SummaryObject(json: value) }
        self.unreferenced = try object["unreferenced"].map { value in try decodeTrue(value) }
        self.groupId = try object["groupId"].map { value in try value.asString() }
        self.json = json
    }
}

/// ISummaryContext: retains the entire received object as its immutable JSON backing store.
public struct ISummaryContext: DriverJSONValue {
    public let json: JSONValue
    public let proposalHandle: JSString?
    public let ackHandle: JSString?
    public let referenceSequenceNumber: Int
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.proposalHandle = try object["proposalHandle"].map { value in try value.asString() }
        self.ackHandle = try object["ackHandle"].map { value in try value.asString() }
        self.referenceSequenceNumber = try decodeInt(json.member("referenceSequenceNumber"))
        self.json = json
    }
}

/// ISnapshotFetchOptions: retains the entire received object as its immutable JSON backing store.
public struct ISnapshotFetchOptions: DriverJSONValue {
    public let json: JSONValue
    public let scenarioName: JSString?
    public let cacheSnapshot: Bool?
    public let versionId: JSString?
    public let loadingGroupIds: [JSString]?
    public let fetchSource: FetchSource?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.scenarioName = try object["scenarioName"].map { value in try value.asString() }
        self.cacheSnapshot = try object["cacheSnapshot"].map { value in try decodeBool(value) }
        self.versionId = try object["versionId"].map { value in try value.asString() }
        self.loadingGroupIds = try object["loadingGroupIds"].map { value in try value.asArray().map { value in try value.asString() } }
        self.fetchSource = try object["fetchSource"].map { value in try FetchSource(json: value) }
        self.json = json
    }
}

/// ISnapshot: retains the entire received object as its immutable JSON backing store.
public struct ISnapshot: DriverJSONValue {
    public let json: JSONValue
    public let snapshotTree: ISnapshotTree
    public let blobContents: SnapshotBlobContents
    public let ops: [ISequencedDocumentMessage]
    public let sequenceNumber: Int?
    public let latestSequenceNumber: Int?
    public let snapshotFormatV: Int
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.snapshotTree = try ISnapshotTree(json: json.member("snapshotTree"))
        self.blobContents = try SnapshotBlobContents(json: json.member("blobContents"))
        self.ops = try json.member("ops").asArray().map { value in try ISequencedDocumentMessage(json: value) }
        self.sequenceNumber = try object["sequenceNumber"].map { value in try decodeInt(value) }
        self.latestSequenceNumber = try object["latestSequenceNumber"].map { value in try decodeInt(value) }
        self.snapshotFormatV = try decodeLiteral(json.member("snapshotFormatV"), 1)
        self.json = json
    }
}

extension ISnapshot {
    /// Driver-authored snapshot. Blob bytes live in `blobContents.buffers`; `json.blobContents`
    /// is `{}`, as JSON.stringify of a Map.
    public init(snapshotTree: ISnapshotTree, blobContents: SnapshotBlobContents, ops: [ISequencedDocumentMessage],
        sequenceNumber: Int?, latestSequenceNumber: Int?)
    {
        var object = JSObject<JSONValue>()
        object["snapshotTree"] = snapshotTree.json
        object["blobContents"] = blobContents.json
        object["ops"] = .array(ops.map(\.json))
        if let sequenceNumber { object["sequenceNumber"] = .number(Double(sequenceNumber)) }
        if let latestSequenceNumber { object["latestSequenceNumber"] = .number(Double(latestSequenceNumber)) }
        object["snapshotFormatV"] = .number(1)
        self.json = .object(object)
        self.snapshotTree = snapshotTree
        self.blobContents = blobContents
        self.ops = ops
        self.sequenceNumber = sequenceNumber
        self.latestSequenceNumber = latestSequenceNumber
        self.snapshotFormatV = 1
    }
}

/// IDeltasFetchResult: retains the entire received object as its immutable JSON backing store.
public struct IDeltasFetchResult: DriverJSONValue {
    public let json: JSONValue
    public let messages: [ISequencedDocumentMessage]
    public let partialResult: Bool
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.messages = try json.member("messages").asArray().map { value in try ISequencedDocumentMessage(json: value) }
        self.partialResult = try decodeBool(json.member("partialResult"))
        self.json = json
    }
}

/// IDocumentMessage: retains the entire received object as its immutable JSON backing store.
public struct IDocumentMessage: DriverJSONValue {
    public let json: JSONValue
    public let clientSequenceNumber: Int
    public let referenceSequenceNumber: Int
    public let type: JSString
    /// unknown includes undefined: nil is absent, `.null` is explicit JSON null.
    public let contents: JSONValue?
    public let metadata: JSONValue?
    public let serverMetadata: JSONValue?
    public let traces: [ITrace]?
    public let compression: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.clientSequenceNumber = try decodeInt(json.member("clientSequenceNumber"))
        self.referenceSequenceNumber = try decodeInt(json.member("referenceSequenceNumber"))
        self.type = try json.member("type").asString()
        self.contents = object["contents"]
        self.metadata = object["metadata"]
        self.serverMetadata = object["serverMetadata"]
        self.traces = try object["traces"].map { value in try value.asArray().map { value in try ITrace(json: value) } }
        self.compression = try object["compression"].map { value in try value.asString() }
        self.json = json
    }
}

/// IDocumentSystemMessage: retains the entire received object as its immutable JSON backing store.
public struct IDocumentSystemMessage: DriverJSONValue {
    public let json: JSONValue
    public let clientSequenceNumber: Int
    public let referenceSequenceNumber: Int
    public let type: JSString
    /// unknown includes undefined: nil is absent, `.null` is explicit JSON null.
    public let contents: JSONValue?
    public let metadata: JSONValue?
    public let serverMetadata: JSONValue?
    public let traces: [ITrace]?
    public let compression: JSString?
    public let data: JSString
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.clientSequenceNumber = try decodeInt(json.member("clientSequenceNumber"))
        self.referenceSequenceNumber = try decodeInt(json.member("referenceSequenceNumber"))
        self.type = try json.member("type").asString()
        self.contents = object["contents"]
        self.metadata = object["metadata"]
        self.serverMetadata = object["serverMetadata"]
        self.traces = try object["traces"].map { value in try value.asArray().map { value in try ITrace(json: value) } }
        self.compression = try object["compression"].map { value in try value.asString() }
        self.data = try json.member("data").asString()
        self.json = json
    }
}

/// ISequencedDocumentMessage: retains the entire received object as its immutable JSON backing store.
public struct ISequencedDocumentMessage: DriverJSONValue {
    public let json: JSONValue
    public let clientId: JSString?
    public let sequenceNumber: Int
    public let minimumSequenceNumber: Int
    public let clientSequenceNumber: Int
    public let referenceSequenceNumber: Int
    public let type: JSString
    /// unknown includes undefined: nil is absent, `.null` is explicit JSON null.
    public let contents: JSONValue?
    public let metadata: JSONValue?
    public let serverMetadata: JSONValue?
    public let traces: [ITrace]?
    public let compression: JSString?
    public let origin: IBranchOrigin?
    public let timestamp: Double
    public let data: JSString?
    public let expHash1: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.clientId = try decodeNullableString(json.member("clientId"))
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.minimumSequenceNumber = try decodeInt(json.member("minimumSequenceNumber"))
        self.clientSequenceNumber = try decodeInt(json.member("clientSequenceNumber"))
        self.referenceSequenceNumber = try decodeInt(json.member("referenceSequenceNumber"))
        self.type = try json.member("type").asString()
        self.contents = object["contents"]
        self.metadata = object["metadata"]
        self.serverMetadata = object["serverMetadata"]
        self.traces = try object["traces"].map { value in try value.asArray().map { value in try ITrace(json: value) } }
        self.compression = try object["compression"].map { value in try value.asString() }
        self.origin = try object["origin"].map { value in try IBranchOrigin(json: value) }
        self.timestamp = try json.member("timestamp").asNumber()
        self.data = try object["data"].map { value in try value.asString() }
        self.expHash1 = try object["expHash1"].map { value in try value.asString() }
        self.json = json
    }
}

/// ISequencedDocumentSystemMessage: retains the entire received object as its immutable JSON backing store.
public struct ISequencedDocumentSystemMessage: DriverJSONValue {
    public let json: JSONValue
    public let clientId: JSString?
    public let sequenceNumber: Int
    public let minimumSequenceNumber: Int
    public let clientSequenceNumber: Int
    public let referenceSequenceNumber: Int
    public let type: JSString
    /// unknown includes undefined: nil is absent, `.null` is explicit JSON null.
    public let contents: JSONValue?
    public let metadata: JSONValue?
    public let serverMetadata: JSONValue?
    public let traces: [ITrace]?
    public let compression: JSString?
    public let origin: IBranchOrigin?
    public let timestamp: Double
    public let data: JSString
    public let expHash1: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.clientId = try decodeNullableString(json.member("clientId"))
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.minimumSequenceNumber = try decodeInt(json.member("minimumSequenceNumber"))
        self.clientSequenceNumber = try decodeInt(json.member("clientSequenceNumber"))
        self.referenceSequenceNumber = try decodeInt(json.member("referenceSequenceNumber"))
        self.type = try json.member("type").asString()
        self.contents = object["contents"]
        self.metadata = object["metadata"]
        self.serverMetadata = object["serverMetadata"]
        self.traces = try object["traces"].map { value in try value.asArray().map { value in try ITrace(json: value) } }
        self.compression = try object["compression"].map { value in try value.asString() }
        self.origin = try object["origin"].map { value in try IBranchOrigin(json: value) }
        self.timestamp = try json.member("timestamp").asNumber()
        self.data = try json.member("data").asString()
        self.expHash1 = try object["expHash1"].map { value in try value.asString() }
        self.json = json
    }
}

/// ISequencedDocumentAugmentedMessage: retains the entire received object as its immutable JSON backing store.
public struct ISequencedDocumentAugmentedMessage: DriverJSONValue {
    public let json: JSONValue
    public let clientId: JSString?
    public let sequenceNumber: Int
    public let minimumSequenceNumber: Int
    public let clientSequenceNumber: Int
    public let referenceSequenceNumber: Int
    public let type: JSString
    /// unknown includes undefined: nil is absent, `.null` is explicit JSON null.
    public let contents: JSONValue?
    public let metadata: JSONValue?
    public let serverMetadata: JSONValue?
    public let traces: [ITrace]?
    public let compression: JSString?
    public let origin: IBranchOrigin?
    public let timestamp: Double
    public let data: JSString?
    public let expHash1: JSString?
    public let additionalContent: JSString
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.clientId = try decodeNullableString(json.member("clientId"))
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.minimumSequenceNumber = try decodeInt(json.member("minimumSequenceNumber"))
        self.clientSequenceNumber = try decodeInt(json.member("clientSequenceNumber"))
        self.referenceSequenceNumber = try decodeInt(json.member("referenceSequenceNumber"))
        self.type = try json.member("type").asString()
        self.contents = object["contents"]
        self.metadata = object["metadata"]
        self.serverMetadata = object["serverMetadata"]
        self.traces = try object["traces"].map { value in try value.asArray().map { value in try ITrace(json: value) } }
        self.compression = try object["compression"].map { value in try value.asString() }
        self.origin = try object["origin"].map { value in try IBranchOrigin(json: value) }
        self.timestamp = try json.member("timestamp").asNumber()
        self.data = try object["data"].map { value in try value.asString() }
        self.expHash1 = try object["expHash1"].map { value in try value.asString() }
        self.additionalContent = try json.member("additionalContent").asString()
        self.json = json
    }
}

/// ISignalMessageBase: retains the entire received object as its immutable JSON backing store.
public struct ISignalMessageBase: DriverJSONValue {
    public let json: JSONValue
    public let content: JSONValue?
    public let type: JSString?
    public let clientConnectionNumber: Int?
    public let referenceSequenceNumber: Int?
    public let targetClientId: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.content = object["content"]
        self.type = try object["type"].map { value in try value.asString() }
        self.clientConnectionNumber = try object["clientConnectionNumber"].map { value in try decodeInt(value) }
        self.referenceSequenceNumber = try object["referenceSequenceNumber"].map { value in try decodeInt(value) }
        self.targetClientId = try object["targetClientId"].map { value in try value.asString() }
        self.json = json
    }
}

/// ISignalMessage: retains the entire received object as its immutable JSON backing store.
public struct ISignalMessage: DriverJSONValue {
    public let json: JSONValue
    public let content: JSONValue?
    public let type: JSString?
    public let clientConnectionNumber: Int?
    public let referenceSequenceNumber: Int?
    public let targetClientId: JSString?
    public let clientId: JSString?
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.content = object["content"]
        self.type = try object["type"].map { value in try value.asString() }
        self.clientConnectionNumber = try object["clientConnectionNumber"].map { value in try decodeInt(value) }
        self.referenceSequenceNumber = try object["referenceSequenceNumber"].map { value in try decodeInt(value) }
        self.targetClientId = try object["targetClientId"].map { value in try value.asString() }
        self.clientId = try decodeNullableString(json.member("clientId"))
        self.json = json
    }
}

/// IProtocolState: retains the entire received object as its immutable JSON backing store.
public struct IProtocolState: DriverJSONValue {
    public let json: JSONValue
    public let sequenceNumber: Int
    public let minimumSequenceNumber: Int
    public let members: [QuorumMember]
    public let proposals: [QuorumProposal]
    public let values: [QuorumValue]
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.sequenceNumber = try decodeInt(json.member("sequenceNumber"))
        self.minimumSequenceNumber = try decodeInt(json.member("minimumSequenceNumber"))
        self.members = try json.member("members").asArray().map { value in try QuorumMember(json: value) }
        self.proposals = try json.member("proposals").asArray().map { value in try QuorumProposal(json: value) }
        self.values = try json.member("values").asArray().map { value in try QuorumValue(json: value) }
        self.json = json
    }
}

public typealias ISentSignalMessage = ISignalMessageBase
public typealias ISequencedDocumentMessageExperimental = ISequencedDocumentMessage

extension ISummaryTree {
    public init(tree: JSObject<SummaryObject>) {
        self.type = 1
        self.tree = tree
        self.unreferenced = nil
        self.groupId = nil
        var children = JSObject<JSONValue>()
        for (name, child) in tree.entries { children[name] = child.json }
        var object = JSObject<JSONValue>()
        object["type"] = .number(1)
        object["tree"] = .object(children)
        json = .object(object)
    }
}


extension ISummaryBlob {
    /// Authored blobs use TS property order; received blobs retain their original backing JSON.
    public init(content: SummaryBlobContent) {
        self.type = 2
        self.content = content
        var object = JSObject<JSONValue>()
        object["type"] = .number(2)
        object["content"] = content.json
        json = .object(object)
    }
}
