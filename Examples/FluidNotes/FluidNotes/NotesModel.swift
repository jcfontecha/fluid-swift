import FluidContainerDefinitions
import FluidOdspClient
import FluidSequence
import FluidStatic
import Foundation
import Observation

/// Sign-in and the one open note. The container is owned by the main actor
/// (`isolation: MainActor.shared`), so this model and the text view read and edit its
/// SharedString directly, and its events arrive synchronously on main.
@MainActor
@Observable
final class NotesModel {
    /// The container schema: one SharedString initial object named "text".
    static let schema = ContainerSchema(initialObjects: ["text": SharedString.self])

    private(set) var isSignedIn: Bool
    private(set) var connection: ConnectionState?
    private(set) var note: NoteText?
    var failure: String?

    private let config: AppConfig
    private let msal: MSALTokenProvider?
    private let tokenProvider: (any IOdspTokenProvider)?
    @ObservationIgnored private var container: FluidContainer?

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
        close()
        connection = .establishingConnection
        let client = OdspClient(properties: OdspClientProps(connection: OdspConnectionConfig(
            tokenProvider: tokenProvider,
            siteUrl: config.siteUrl,
            driveId: config.driveId,
            filePath: ""
        )))
        do {
            let (container, _) = try await client.getContainer(
                itemId, containerSchema: Self.schema, isolation: MainActor.shared)
            guard let text = container.initialObjects["text"] as? SharedString else {
                container.dispose()
                throw NotesError.missingText
            }
            // No await from here on: no container event or remote op can run before both
            // listeners are installed.
            self.container = container
            note = NoteText(text: text) { [weak self] error in
                self?.failure = error.localizedDescription
            }
            connection = container.connectionState
            container.events.on { [weak self] event in
                self?.containerChanged(event)
            }
        } catch {
            connection = nil
            failure = error.localizedDescription
        }
    }

    private func close() {
        container?.dispose()
        container = nil
        note = nil
        connection = nil
    }

    private func containerChanged(_ event: FluidContainerEvent) {
        switch event {
        case .connected, .disconnected:
            connection = container?.connectionState
        case let .disposed(error):
            connection = .disconnected
            if let error {
                failure = error.localizedDescription
            }
        case .saved, .dirty:
            break
        }
    }
}

enum NotesError: LocalizedError {
    case missingText

    var errorDescription: String? {
        switch self {
        case .missingText:
            "This item has no text."
        }
    }
}
