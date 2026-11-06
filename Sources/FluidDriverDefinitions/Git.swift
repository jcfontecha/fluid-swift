import FluidJS

/// Git REST resources, namespaced to avoid collisions with protocol storage types.
public enum Git {
/// IAuthor: retains the entire received object as its immutable JSON backing store.
public struct IAuthor: DriverJSONValue {
    public let json: JSONValue
    public let name: JSString
    public let email: JSString
    public let date: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.name = try json.member("name").asString()
        self.email = try json.member("email").asString()
        self.date = try json.member("date").asString()
        self.json = json
    }
}

/// ICommitter: retains the entire received object as its immutable JSON backing store.
public struct ICommitter: DriverJSONValue {
    public let json: JSONValue
    public let name: JSString
    public let email: JSString
    public let date: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.name = try json.member("name").asString()
        self.email = try json.member("email").asString()
        self.date = try json.member("date").asString()
        self.json = json
    }
}

/// ICommitHash: retains the entire received object as its immutable JSON backing store.
public struct ICommitHash: DriverJSONValue {
    public let json: JSONValue
    public let sha: JSString
    public let url: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.sha = try json.member("sha").asString()
        self.url = try json.member("url").asString()
        self.json = json
    }
}

/// ICreateCommitParams: retains the entire received object as its immutable JSON backing store.
public struct ICreateCommitParams: DriverJSONValue {
    public let json: JSONValue
    public let message: JSString
    public let tree: JSString
    public let parents: [JSString]
    public let author: Git.IAuthor
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.message = try json.member("message").asString()
        self.tree = try json.member("tree").asString()
        self.parents = try json.member("parents").asArray().map { value in try value.asString() }
        self.author = try Git.IAuthor(json: json.member("author"))
        self.json = json
    }
}

/// ICommit: retains the entire received object as its immutable JSON backing store.
public struct ICommit: DriverJSONValue {
    public let json: JSONValue
    public let sha: JSString
    public let url: JSString
    public let author: Git.IAuthor
    public let committer: Git.ICommitter
    public let message: JSString
    public let tree: Git.ICommitHash
    public let parents: [Git.ICommitHash]
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.sha = try json.member("sha").asString()
        self.url = try json.member("url").asString()
        self.author = try Git.IAuthor(json: json.member("author"))
        self.committer = try Git.ICommitter(json: json.member("committer"))
        self.message = try json.member("message").asString()
        self.tree = try Git.ICommitHash(json: json.member("tree"))
        self.parents = try json.member("parents").asArray().map { value in try Git.ICommitHash(json: value) }
        self.json = json
    }
}

/// ICommitDetails: retains the entire received object as its immutable JSON backing store.
public struct ICommitDetails: DriverJSONValue {
    public let json: JSONValue
    public let url: JSString
    public let sha: JSString
    public let commit: Git.CommitDetail
    public let parents: [Git.ICommitHash]
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.url = try json.member("url").asString()
        self.sha = try json.member("sha").asString()
        self.commit = try Git.CommitDetail(json: json.member("commit"))
        self.parents = try json.member("parents").asArray().map { value in try Git.ICommitHash(json: value) }
        self.json = json
    }
}

/// CommitDetail: retains the entire received object as its immutable JSON backing store.
public struct CommitDetail: DriverJSONValue {
    public let json: JSONValue
    public let url: JSString
    public let author: Git.IAuthor
    public let committer: Git.ICommitter
    public let message: JSString
    public let tree: Git.ICommitHash
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.url = try json.member("url").asString()
        self.author = try Git.IAuthor(json: json.member("author"))
        self.committer = try Git.ICommitter(json: json.member("committer"))
        self.message = try json.member("message").asString()
        self.tree = try Git.ICommitHash(json: json.member("tree"))
        self.json = json
    }
}

/// IBlob: retains the entire received object as its immutable JSON backing store.
public struct IBlob: DriverJSONValue {
    public let json: JSONValue
    public let content: JSString
    public let encoding: JSString
    public let url: JSString
    public let sha: JSString
    public let size: Double
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.content = try json.member("content").asString()
        self.encoding = try json.member("encoding").asString()
        self.url = try json.member("url").asString()
        self.sha = try json.member("sha").asString()
        self.size = try json.member("size").asNumber()
        self.json = json
    }
}

/// ICreateBlobParams: retains the entire received object as its immutable JSON backing store.
public struct ICreateBlobParams: DriverJSONValue {
    public let json: JSONValue
    public let content: JSString
    public let encoding: BlobEncoding
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.content = try json.member("content").asString()
        self.encoding = try BlobEncoding(json: json.member("encoding"))
        self.json = json
    }
}

/// ICreateBlobResponse: retains the entire received object as its immutable JSON backing store.
public struct ICreateBlobResponse: DriverJSONValue {
    public let json: JSONValue
    public let sha: JSString
    public let url: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.sha = try json.member("sha").asString()
        self.url = try json.member("url").asString()
        self.json = json
    }
}

/// ObjectReference: retains the entire received object as its immutable JSON backing store.
public struct ObjectReference: DriverJSONValue {
    public let json: JSONValue
    public let type: JSString
    public let sha: JSString
    public let url: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.type = try json.member("type").asString()
        self.sha = try json.member("sha").asString()
        self.url = try json.member("url").asString()
        self.json = json
    }
}

/// IRef: retains the entire received object as its immutable JSON backing store.
public struct IRef: DriverJSONValue {
    public let json: JSONValue
    public let ref: JSString
    public let url: JSString
    public let object: Git.ObjectReference
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.ref = try json.member("ref").asString()
        self.url = try json.member("url").asString()
        self.object = try Git.ObjectReference(json: json.member("object"))
        self.json = json
    }
}

/// ICreateRefParams: retains the entire received object as its immutable JSON backing store.
public struct ICreateRefParams: DriverJSONValue {
    public let json: JSONValue
    public let ref: JSString
    public let sha: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.ref = try json.member("ref").asString()
        self.sha = try json.member("sha").asString()
        self.json = json
    }
}

/// IPatchRefParams: retains the entire received object as its immutable JSON backing store.
public struct IPatchRefParams: DriverJSONValue {
    public let json: JSONValue
    public let sha: JSString
    public let force: Bool
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.sha = try json.member("sha").asString()
        self.force = try decodeBool(json.member("force"))
        self.json = json
    }
}

/// ICreateRepoParams: retains the entire received object as its immutable JSON backing store.
public struct ICreateRepoParams: DriverJSONValue {
    public let json: JSONValue
    public let name: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.name = try json.member("name").asString()
        self.json = json
    }
}

/// ICreateTreeEntry: retains the entire received object as its immutable JSON backing store.
public struct ICreateTreeEntry: DriverJSONValue {
    public let json: JSONValue
    public let path: JSString
    public let mode: JSString
    public let type: JSString
    public let sha: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.path = try json.member("path").asString()
        self.mode = try json.member("mode").asString()
        self.type = try json.member("type").asString()
        self.sha = try json.member("sha").asString()
        self.json = json
    }
}

/// ICreateTreeParams: retains the entire received object as its immutable JSON backing store.
public struct ICreateTreeParams: DriverJSONValue {
    public let json: JSONValue
    public let base_tree: JSString?
    public let tree: [Git.ICreateTreeEntry]
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        self.base_tree = try object["base_tree"].map { value in try value.asString() }
        self.tree = try json.member("tree").asArray().map { value in try Git.ICreateTreeEntry(json: value) }
        self.json = json
    }
}

/// ITreeEntry: retains the entire received object as its immutable JSON backing store.
public struct ITreeEntry: DriverJSONValue {
    public let json: JSONValue
    public let path: JSString
    public let mode: JSString
    public let type: JSString
    public let size: Double
    public let sha: JSString
    public let url: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.path = try json.member("path").asString()
        self.mode = try json.member("mode").asString()
        self.type = try json.member("type").asString()
        self.size = try json.member("size").asNumber()
        self.sha = try json.member("sha").asString()
        self.url = try json.member("url").asString()
        self.json = json
    }
}

/// ITree: retains the entire received object as its immutable JSON backing store.
public struct ITree: DriverJSONValue {
    public let json: JSONValue
    public let sha: JSString
    public let url: JSString
    public let tree: [Git.ITreeEntry]
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.sha = try json.member("sha").asString()
        self.url = try json.member("url").asString()
        self.tree = try json.member("tree").asArray().map { value in try Git.ITreeEntry(json: value) }
        self.json = json
    }
}

/// ITagger: retains the entire received object as its immutable JSON backing store.
public struct ITagger: DriverJSONValue {
    public let json: JSONValue
    public let name: JSString
    public let email: JSString
    public let date: JSString
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.name = try json.member("name").asString()
        self.email = try json.member("email").asString()
        self.date = try json.member("date").asString()
        self.json = json
    }
}

/// ICreateTagParams: retains the entire received object as its immutable JSON backing store.
public struct ICreateTagParams: DriverJSONValue {
    public let json: JSONValue
    public let tag: JSString
    public let message: JSString
    public let object: JSString
    public let type: JSString
    public let tagger: Git.ITagger
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.tag = try json.member("tag").asString()
        self.message = try json.member("message").asString()
        self.object = try json.member("object").asString()
        self.type = try json.member("type").asString()
        self.tagger = try Git.ITagger(json: json.member("tagger"))
        self.json = json
    }
}

/// ITag: retains the entire received object as its immutable JSON backing store.
public struct ITag: DriverJSONValue {
    public let json: JSONValue
    public let tag: JSString
    public let sha: JSString
    public let url: JSString
    public let message: JSString
    public let tagger: Git.ITagger
    public let object: Git.ObjectReference
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.tag = try json.member("tag").asString()
        self.sha = try json.member("sha").asString()
        self.url = try json.member("url").asString()
        self.message = try json.member("message").asString()
        self.tagger = try Git.ITagger(json: json.member("tagger"))
        self.object = try Git.ObjectReference(json: json.member("object"))
        self.json = json
    }
}

}
