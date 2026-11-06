import FluidOdspClient
import MSAL
import UIKit

/// `IOdspTokenProvider` backed by MSAL: silent acquisition from MSAL's cache, interactive when
/// MSAL reports that interaction is required.
@MainActor
final class MSALTokenProvider: IOdspTokenProvider {
    // Scopes match the official odsp-client sample token provider:
    // https://github.com/microsoft/FluidFramework/blob/main/examples/service-clients/odsp-client/shared-tree-demo/src/tokenProvider.ts
    // That sample also lists `offline_access` with the push scope. MSAL for iOS always adds
    // openid, profile and offline_access itself (`MSALPublicClientApplication.defaultOIDCScopes`),
    // so it is not repeated here.

    /// Sign-in scope (`loginPopup` in the sample).
    nonisolated static let signInScopes = ["FileStorageContainer.Selected"]
    /// `fetchWebsocketToken` scope.
    nonisolated static let pushScopes = ["https://pushchannel.1drv.ms/PushChannel.ReadWrite.All"]
    /// `fetchStorageToken` scope.
    nonisolated static func storageScopes(siteUrl: String) -> [String] {
        ["\(siteUrl)/Container.Selected"]
    }

    private let application: MSALPublicClientApplication
    private(set) var account: MSALAccount?

    init(clientId: String, tenantId: String) throws {
        let authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/\(tenantId)")!)
        let configuration = MSALPublicClientApplicationConfig(clientId: clientId, redirectUri: nil, authority: authority)
        application = try MSALPublicClientApplication(configuration: configuration)
        account = try application.allAccounts().first
    }

    func signIn() async throws {
        let result = try await acquireInteractively(scopes: Self.signInScopes)
        account = result.account
    }

    nonisolated func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        try await token(scopes: Self.storageScopes(siteUrl: siteUrl), refresh: refresh)
    }

    nonisolated func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        try await token(scopes: Self.pushScopes, refresh: refresh)
    }

    private func token(scopes: [String], refresh: Bool) async throws -> TokenResponse {
        guard let account else {
            let result = try await acquireInteractively(scopes: scopes)
            self.account = result.account
            return TokenResponse(token: result.accessToken, fromCache: false)
        }
        let parameters = MSALSilentTokenParameters(scopes: scopes, account: account)
        parameters.forceRefresh = refresh
        do {
            let result = try await acquire(silently: parameters)
            return TokenResponse(token: result.accessToken, fromCache: nil)
        } catch let error as NSError where error.domain == MSALErrorDomain && error.code == MSALError.interactionRequired.rawValue {
            let result = try await acquireInteractively(scopes: scopes)
            self.account = result.account
            return TokenResponse(token: result.accessToken, fromCache: false)
        }
    }

    private func acquire(silently parameters: MSALSilentTokenParameters) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: error!)
                }
            }
        }
    }

    private func acquireInteractively(scopes: [String]) async throws -> MSALResult {
        let webview = MSALWebviewParameters(authPresentationViewController: try Self.presenter())
        let parameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webview)
        parameters.account = account
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: error!)
                }
            }
        }
    }

    /// The topmost view controller of the foreground window, which MSAL presents its web view on.
    private static func presenter() throws -> UIViewController {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var controller = scene?.keyWindow?.rootViewController else {
            throw MSALPresentationError()
        }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
}

/// No foreground window is available to present Microsoft sign-in on.
struct MSALPresentationError: LocalizedError {
    var errorDescription: String? { "Sign-in needs the app in the foreground." }
}
