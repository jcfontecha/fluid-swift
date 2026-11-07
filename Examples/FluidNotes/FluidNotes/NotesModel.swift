import Fluid
import Foundation
import Observation

/// The container schema: one SharedString initial object named "text".
struct Note: ContainerSchema {
    let text: SharedString

    init(_ objects: InitialObjects) {
        text = objects["text"]
    }
}

/// Sign-in and the one open note. The container is owned by the main actor
/// (`isolation: MainActor.shared`), so this model and the text view read and edit its
/// SharedString directly, and its changes arrive synchronously on main.
@MainActor
@Observable
final class NotesModel {
    private(set) var isSignedIn: Bool
    private(set) var isOpening = false
    private(set) var container: FluidContainer<Note>?
    private(set) var note: NoteText?
    var failure: String?

    private let config: AppConfig
    private let msal: MSALTokenProvider?
    private let tokenProvider: (any OdspTokenProvider)?

    init(config: AppConfig) {
        self.config = config
        switch config.signIn {
        case let .microsoft(clientId, tenantId):
            do {
                let provider = try MSALTokenProvider(clientId: clientId, tenantId: tenantId)
                msal = provider
                tokenProvider = provider
                isSignedIn = provider.account != nil
            } catch {
                msal = nil
                tokenProvider = nil
                isSignedIn = false
                failure = error.localizedDescription
            }
        case let .local(user):
            msal = nil
            tokenProvider = LocalTokenProvider(user: user)
            isSignedIn = true
        }
    }

    func signIn() async {
        guard let msal else { return }
        do {
            try await msal.signIn()
            isSignedIn = true
        } catch {
            failure = error.localizedDescription
        }
    }

    func open(itemId: String) async {
        guard let client else { return }
        note = nil
        container = nil
        isOpening = true
        defer { isOpening = false }
        do {
            let container = try await client.loadContainer(itemId, schema: Note.self, isolation: MainActor.shared)
            // No await from here on: no remote op can run before the editor's handler is installed.
            self.container = container
            note = NoteText(text: container.initialObjects.text)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Creates a note and stores it as a new file. The editor takes typing right away, and what
    /// is typed before the attach finishes is stored with it. Returns the new item id, or nil when
    /// the attach failed: that closes the container, whose error `closeFailure` reports.
    func create() async -> String? {
        guard let client else { return nil }
        let container = await client.createContainer(schema: Note.self, isolation: MainActor.shared)
        self.container = container
        note = NoteText(text: container.initialObjects.text)
        return try? await container.attach()
    }

    private var client: OdspClient? {
        tokenProvider.map { OdspClient(siteURL: config.siteURL, driveID: config.driveId, tokenProvider: $0) }
    }

    /// The error the open container closed with.
    var closeFailure: String? {
        guard case let .closed(error?) = container?.status else { return nil }
        return error.localizedDescription
    }
}
