import FluidJS

/// All four summary variants. Received variants retain their full immutable JSON backing stores.
public indirect enum SummaryObject: Equatable, Sendable, DriverJSONValue {
    case tree(ISummaryTree)
    case blob(ISummaryBlob)
    case handle(ISummaryHandle)
    case attachment(ISummaryAttachment)

    public init(json: JSONValue) throws {
        switch try SummaryType(json: json.member("type")) {
        case .tree: self = .tree(try ISummaryTree(json: json))
        case .blob: self = .blob(try ISummaryBlob(json: json))
        case .handle: self = .handle(try ISummaryHandle(json: json))
        case .attachment: self = .attachment(try ISummaryAttachment(json: json))
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }

    public var json: JSONValue {
        switch self {
        case .tree(let value): value.json
        case .blob(let value): value.json
        case .handle(let value): value.json
        case .attachment(let value): value.json
        }
    }
}

/// TS SummaryTree union: either a tree or a handle to a previous tree.
/// Received variants retain the original JSON; authored trees use TS property order.
public enum SummaryTree: Equatable, Sendable, DriverJSONValue {
    case tree(ISummaryTree)
    case handle(ISummaryHandle)

    public init(tree: JSObject<SummaryObject> = JSObject()) {
        self = .tree(ISummaryTree(tree: tree))
    }

    public init(json: JSONValue) throws {
        switch try SummaryType(json: json.member("type")) {
        case .tree: self = .tree(try ISummaryTree(json: json))
        case .handle: self = .handle(try ISummaryHandle(json: json))
        default: throw JSONDecodingError("expected tree or handle")
        }
    }

    public var json: JSONValue {
        switch self {
        case .tree(let value): value.json
        case .handle(let value): value.json
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }

    /// createSingleBlobSummary from shared-object-base.
    public static func singleBlob(_ name: JSString, _ content: JSString) -> SummaryTree {
        var tree = JSObject<SummaryObject>()
        tree[name] = .blob(ISummaryBlob(content: .text(content)))
        return SummaryTree(tree: tree)
    }

    /// readAndParse: the JSON content of a top-level blob.
    public func readAndParse(_ name: JSString) throws -> JSONValue {
        guard case .tree(let summary) = self, let object = summary.tree[name],
              try SummaryType(json: object.json.member("type")) == .blob else {
            throw JSONDecodingError("missing summary blob")
        }
        let content = try object.json.member("content").asString()
        return try JSON.parse(content.description)
    }
}
