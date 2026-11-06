import FluidJS

/// `SummaryType` from protocol-definitions.
public enum SummaryType: Int, Sendable {
    case tree = 1
    case blob = 2
}

/// `SummaryObject` (tree and string blob; handles, attachments and binary blobs come later).
public indirect enum SummaryObject: Equatable, Sendable {
    case tree(SummaryTree)
    case blob(JSString)

    public init(json: JSONValue) throws {
        switch try json.member("type").asInt() {
        case SummaryType.tree.rawValue:
            self = .tree(try SummaryTree(json: json))
        case SummaryType.blob.rawValue:
            self = .blob(try json.member("content").asString())
        case let type:
            throw JSONDecodingError("unsupported summary type \(type)")
        }
    }

    public var json: JSONValue {
        switch self {
        case .tree(let tree):
            return tree.json
        case .blob(let content):
            var object = JSObject<JSONValue>()
            object["type"] = .number(Double(SummaryType.blob.rawValue))
            object["content"] = .string(content)
            return .object(object)
        }
    }
}

/// `ISummaryTree`.
public struct SummaryTree: Equatable, Sendable {
    public var tree: JSObject<SummaryObject>

    public init(tree: JSObject<SummaryObject> = JSObject()) {
        self.tree = tree
    }

    public init(json: JSONValue) throws {
        guard try json.member("type").asInt() == SummaryType.tree.rawValue else {
            throw JSONDecodingError("expected summary tree")
        }
        tree = JSObject()
        for (name, object) in try json.member("tree").asObject().entries {
            tree[name] = try SummaryObject(json: object)
        }
    }

    public var json: JSONValue {
        var children = JSObject<JSONValue>()
        for (name, object) in tree.entries {
            children[name] = object.json
        }
        var object = JSObject<JSONValue>()
        object["type"] = .number(Double(SummaryType.tree.rawValue))
        object["tree"] = .object(children)
        return .object(object)
    }

    /// `createSingleBlobSummary` from shared-object-base.
    public static func singleBlob(_ name: JSString, _ content: JSString) -> SummaryTree {
        var tree = JSObject<SummaryObject>()
        tree[name] = .blob(content)
        return SummaryTree(tree: tree)
    }

    /// `readAndParse`: the JSON content of a top-level blob.
    public func readAndParse(_ name: JSString) throws -> JSONValue {
        guard case .blob(let content) = tree[name] else {
            throw JSONDecodingError("summary has no blob \"\(name)\"")
        }
        return try JSON.parse(content.description)
    }
}
