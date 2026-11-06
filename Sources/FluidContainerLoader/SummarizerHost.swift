import FluidJS

/// The owner of a summarizer child container (summaryManager.ts, createSummarizer.ts). TS runs the
/// summarizer as a second container on the same JS thread. Here it is a separate graph on its own
/// actor, so summarizing never runs on the parent's owner (ARCHITECTURE.md section 2). The parent
/// reaches the child only through these calls, with Sendable values. The child reaches the parent
/// only through its `stopped` notice, a job on the parent's loop.
actor SummarizerHost {
    private let container: Container

    init(_ container: sending Container) {
        self.container = container
    }

    /// createSummarizer.ts: loads, connects and catches up the child, then adopts it here. With a
    /// parent id the child summarizes on its own heuristics and reports when it stops.
    func open(parentClientId: JSString?, generation: Int?, stopped: (@Sendable (Int) -> Void)?) async throws {
        if let parentClientId, let generation, let stopped {
            container.startSummarizer(parentClientId: parentClientId, generation: generation, stopped: stopped)
        }
        try await container.open()
        container.start(on: self)
    }

    func summarize() async throws -> JSONValue {
        try await container.summarize()
    }

    /// The child's view, or nil before it has loaded.
    func view() throws -> JSONValue? {
        container.loaded ? try container.view() : nil
    }

    func submit(type: String, contents: JSONValue?) throws {
        try container.submit(type: type, contents: contents)
    }

    /// summaryManager.ts stop: a graceful stop, which may run a last summary, bounded by 120 s.
    /// When it fails or times out, the child disconnects.
    func stop(reason: String) async throws {
        let timeout = Task {
            do { try await Task.sleep(for: .milliseconds(120000)) } catch { return }
            container.disconnect()
        }
        defer { timeout.cancel() }
        do {
            try await container.stopGracefully(reason: reason)
        } catch {
            container.disconnect()
            throw error
        }
    }

    func disconnect() {
        container.disconnect()
    }
}
