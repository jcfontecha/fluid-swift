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
        guard let tokenProvider else { return }
        note = nil
        container = nil
        isOpening = true
        defer { isOpening = false }
        let client = OdspClient(siteURL: config.siteURL, driveID: config.driveId, tokenProvider: tokenProvider)
        do {
            let container = try await client.loadContainer(itemId, schema: Note.self, isolation: MainActor.shared)
            // No await from here on: no remote op can run before the editor's handler is installed.
            self.container = container
            note = NoteText(text: container.initialObjects.text)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The error the open container closed with.
    var closeFailure: String? {
        guard case let .closed(error?) = container?.status else { return nil }
        return error.localizedDescription
    }
}
