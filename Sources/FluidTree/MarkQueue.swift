import FluidJS

/// feature-libraries/sequence-field/markQueue.ts.
public class MarkQueueBase {
    private var stack: [SequenceMark] = []
    private var index = 0
    private let list: [SequenceMark]
    public init(_ list: [SequenceMark]) {
        self.list = list
    }
    public func isEmpty() throws -> Bool {
        try peek() == nil
    }
    public func dequeue() throws -> SequenceMark {
        guard let result = try tryDequeue() else {
            throw JSONDecodingError("0x4e2: unexpected end of mark queue")
        }
        return result
    }
    public func tryDequeue() throws -> SequenceMark? {
        let mark: SequenceMark
        if let cached = stack.popLast() {
            mark = cached
        } else {
            guard index < list.count else { return nil }
            mark = list[index]
            index += 1
        }
        let length = try getLengthForSplit(mark)
        if length < mark.count {
            let (first, second) = try mark.split(length)
            stack.append(second)
            return first
        }
        return mark
    }
    public func dequeueUpTo(_ length: Int) throws -> SequenceMark {
        let mark = try dequeue()
        if mark.count <= length { return mark }
        let (first, second) = try mark.split(length)
        stack.append(second)
        return first
    }
    public func peek() throws -> SequenceMark? {
        let mark = try tryDequeue()
        if let mark { stack.append(mark) }
        return mark
    }
    func getLengthForSplit(_ mark: SequenceMark) throws -> Int {
        mark.count
    }
}

/// feature-libraries/sequence-field/markQueue.ts.
public final class MarkQueue<M: CrossFieldManager>: MarkQueueBase where M.Value == MoveEffect {
    private let manager: M
    public init(_ list: [SequenceMark], manager: M) {
        self.manager = manager
        super.init(list)
    }
    override func getLengthForSplit(_ mark: SequenceMark) throws -> Int {
        try firstMoveEffectLength(mark.effect, count: mark.count, manager: manager)
    }
}
