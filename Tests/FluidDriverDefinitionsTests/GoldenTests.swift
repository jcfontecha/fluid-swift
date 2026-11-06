import Testing
import Foundation
import FluidJS
import FluidDriverDefinitions

@Suite struct FluidDriverDefinitionsTests {
    func roundTrip(_ type: String, _ json: JSONValue) throws -> JSONValue {
        switch type {
        case "ISentSignalMessage": return try ISentSignalMessage(json: json).json
        case "ISequencedDocumentMessageExperimental": return try ISequencedDocumentMessageExperimental(json: json).json
        case "SummaryTree": return try SummaryTree(json: json).json
        case "FiveDaysMs": return try FiveDaysMs(json: json).json
        case "IsoDate": return try IsoDate(json: json).json
        case "LoaderCachingPolicy": return try LoaderCachingPolicy(json: json).json
        case "ICapabilities": return try ICapabilities(json: json).json
        case "IClientDetails": return try IClientDetails(json: json).json
        case "IUser": return try IUser(json: json).json
        case "IClient": return try IClient(json: json).json
        case "ISequencedClient": return try ISequencedClient(json: json).json
        case "ISignalClient": return try ISignalClient(json: json).json
        case "IClientJoin": return try IClientJoin(json: json).json
        case "IClientConfiguration": return try IClientConfiguration(json: json).json
        case "IProposal": return try IProposal(json: json).json
        case "ISequencedProposal": return try ISequencedProposal(json: json).json
        case "IApprovedProposal": return try IApprovedProposal(json: json).json
        case "ICommittedProposal": return try ICommittedProposal(json: json).json
        case "IProcessMessageResult": return try IProcessMessageResult(json: json).json
        case "ITrace": return try ITrace(json: json).json
        case "IBranchOrigin": return try IBranchOrigin(json: json).json
        case "INackContent": return try INackContent(json: json).json
        case "INack": return try INack(json: json).json
        case "IUploadedSummaryDetails": return try IUploadedSummaryDetails(json: json).json
        case "ISummaryContent": return try ISummaryContent(json: json).json
        case "IServerError": return try IServerError(json: json).json
        case "ISummaryProposal": return try ISummaryProposal(json: json).json
        case "ISummaryAck": return try ISummaryAck(json: json).json
        case "ISummaryNack": return try ISummaryNack(json: json).json
        case "ITokenClaims": return try ITokenClaims(json: json).json
        case "IConnect": return try IConnect(json: json).json
        case "IConnected": return try IConnected(json: json).json
        case "IDocumentAttributes": return try IDocumentAttributes(json: json).json
        case "IBlob": return try IBlob(json: json).json
        case "IAttachment": return try IAttachment(json: json).json
        case "ICreateBlobResponse": return try ICreateBlobResponse(json: json).json
        case "ITree": return try ITree(json: json).json
        case "ISnapshotTree": return try ISnapshotTree(json: json).json
        case "ISnapshotTreeEx": return try ISnapshotTreeEx(json: json).json
        case "IVersion": return try IVersion(json: json).json
        case "ISummaryHandle": return try ISummaryHandle(json: json).json
        case "ISummaryBlob": return try ISummaryBlob(json: json).json
        case "ISummaryAttachment": return try ISummaryAttachment(json: json).json
        case "ISummaryTree": return try ISummaryTree(json: json).json
        case "ISummaryContext": return try ISummaryContext(json: json).json
        case "ISnapshotFetchOptions": return try ISnapshotFetchOptions(json: json).json
        case "ISnapshot": return try ISnapshot(json: json).json
        case "IDeltasFetchResult": return try IDeltasFetchResult(json: json).json
        case "IDocumentMessage": return try IDocumentMessage(json: json).json
        case "IDocumentSystemMessage": return try IDocumentSystemMessage(json: json).json
        case "ISequencedDocumentMessage": return try ISequencedDocumentMessage(json: json).json
        case "ISequencedDocumentSystemMessage": return try ISequencedDocumentSystemMessage(json: json).json
        case "ISequencedDocumentAugmentedMessage": return try ISequencedDocumentAugmentedMessage(json: json).json
        case "ISignalMessageBase": return try ISignalMessageBase(json: json).json
        case "ISignalMessage": return try ISignalMessage(json: json).json
        case "IProtocolState": return try IProtocolState(json: json).json
        case "Git.IAuthor": return try Git.IAuthor(json: json).json
        case "Git.ICommitter": return try Git.ICommitter(json: json).json
        case "Git.ICommitHash": return try Git.ICommitHash(json: json).json
        case "Git.ICreateCommitParams": return try Git.ICreateCommitParams(json: json).json
        case "Git.ICommit": return try Git.ICommit(json: json).json
        case "Git.ICommitDetails": return try Git.ICommitDetails(json: json).json
        case "Git.CommitDetail": return try Git.CommitDetail(json: json).json
        case "Git.IBlob": return try Git.IBlob(json: json).json
        case "Git.ICreateBlobParams": return try Git.ICreateBlobParams(json: json).json
        case "Git.ICreateBlobResponse": return try Git.ICreateBlobResponse(json: json).json
        case "Git.ObjectReference": return try Git.ObjectReference(json: json).json
        case "Git.IRef": return try Git.IRef(json: json).json
        case "Git.ICreateRefParams": return try Git.ICreateRefParams(json: json).json
        case "Git.IPatchRefParams": return try Git.IPatchRefParams(json: json).json
        case "Git.ICreateRepoParams": return try Git.ICreateRepoParams(json: json).json
        case "Git.ICreateTreeEntry": return try Git.ICreateTreeEntry(json: json).json
        case "Git.ICreateTreeParams": return try Git.ICreateTreeParams(json: json).json
        case "Git.ITreeEntry": return try Git.ITreeEntry(json: json).json
        case "Git.ITree": return try Git.ITree(json: json).json
        case "Git.ITagger": return try Git.ITagger(json: json).json
        case "Git.ICreateTagParams": return try Git.ICreateTagParams(json: json).json
        case "Git.ITag": return try Git.ITag(json: json).json
        case "ConnectionMode": return try ConnectionMode(json: json).json
        case "MessageType": return try MessageType(json: json).json
        case "SignalType": return try SignalType(json: json).json
        case "NackErrorType": return try NackErrorType(json: json).json
        case "ScopeType": return try ScopeType(json: json).json
        case "FileMode": return try FileMode(json: json).json
        case "TreeEntry": return try TreeEntry(json: json).json
        case "BlobEncoding": return try BlobEncoding(json: json).json
        case "FetchSource": return try FetchSource(json: json).json
        case "SummaryBlobContent": return try SummaryBlobContent(json: json).json
        case "ITreeEntry": return try ITreeEntry(json: json).json
        case "SummaryObject": return try SummaryObject(json: json).json
        case "SummaryType": return try SummaryType(json: json).json
        case "SummaryTypeNoHandle": return try SummaryTypeNoHandle(json: json).json
        case "SummaryTreeReference": return try SummaryTreeReference(json: json).json
        case "UnsequencedMessage": return try UnsequencedMessage(json: json).json
        case "SequencedMessage": return try SequencedMessage(json: json).json
        default: throw JSONDecodingError("unregistered fixture type \(type)")
        }
    }

    @Test(arguments: ["session", "edges"])
    func golden(_ fixture: String) throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
        let records = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
        #expect(!records.isEmpty)
        for record in records {
            let type = try record.member("type").asString().description
            let text = try record.member("text").asString().description
            let json = try JSON.parse(text)
            #expect(try JSON.stringify(roundTrip(type, json)) == text, "\(fixture): \(type)")
        }
    }

    @Test func rejectsInvalidData() throws {
        let inputs = [
            ("IBranchOrigin", "{\"id\":\"branch\",\"sequenceNumber\":1.5,\"minimumSequenceNumber\":0}"),
            ("IBranchOrigin", "{\"id\":\"branch\",\"sequenceNumber\":9007199254740992,\"minimumSequenceNumber\":0}"),
            ("ISequencedClient", "{\"client\":{},\"sequenceNumber\":1.5}"),
            ("SummaryObject", "{\"type\":5}"),
            ("SummaryTypeNoHandle", "3"),
            ("FiveDaysMs", "432000001"),
            ("SummaryBlobContent", "{\"0\":256}"),
            ("SummaryBlobContent", "[1,2]"),
            ("IProtocolState", "{\"sequenceNumber\":9007199254740992}"),
            ("IUser", "{\"id\":null}")
        ]
        for (type, text) in inputs {
            #expect(throws: (any Error).self) { try roundTrip(type, JSON.parse(text)) }
        }
    }

    @Test func sessionExercisedRealCollaboration() throws {
        let url = try #require(Bundle.module.url(forResource: "session", withExtension: "json", subdirectory: "Fixtures"))
        let records = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
        let messages = try records.filter { try $0.member("type").asString() == "ISequencedDocumentMessage" }
            .map { try ISequencedDocumentMessage(json: JSON.parse($0.member("text").asString().description)) }
        #expect(messages.contains { $0.type == "op" })
        #expect(messages.contains { $0.type == "propose" })
        #expect(messages.contains { $0.type == "summaryAck" })
        let record = try #require(records.first { try $0.member("type").asString() == "IProtocolState" })
        let state = try IProtocolState(json: JSON.parse(record.member("text").asString().description))
        #expect(state.members.count >= 2)
        #expect(state.values.contains { $0.key == "golden-proposal" && $0.proposal.value != nil })
    }

    @Test func absenceNullAndNestedTypes() throws {
        let absent = try IDocumentMessage(json: JSON.parse("{\"type\":\"noop\",\"clientSequenceNumber\":1,\"referenceSequenceNumber\":0}"))
        #expect(absent.contents == nil)
        #expect(absent.metadata == nil)
        let explicit = try IDocumentMessage(json: JSON.parse("{\"type\":\"noop\",\"clientSequenceNumber\":1,\"referenceSequenceNumber\":0,\"contents\":null,\"metadata\":null}"))
        #expect(explicit.contents == .some(.null))
        #expect(explicit.metadata == .some(.null))
        #expect(try explicit.json.asObject()["metadata"] == .some(.null))
        let binary = try ISummaryBlob(json: JSON.parse("{\"type\":2,\"content\":{\"0\":0,\"1\":255}}"))
        guard case .binary(let bytes) = binary.content else { Issue.record("expected binary content"); return }
        #expect(bytes == [0, 255])
        let treeHandle = try SummaryTree(json: JSON.parse("{\"type\":3,\"handleType\":1,\"handle\":\"/previous\"}"))
        guard case .handle(let handle) = treeHandle else { Issue.record("expected tree handle"); return }
        #expect(handle.handle == "/previous")
    }
}
