import Foundation

/// Per-tenant app configuration. None of these values are secrets.
struct AppConfig {
    enum SignIn {
        /// Entra ID app registration used by MSAL.
        case microsoft(clientId: String, tenantId: String)
        /// The local ODSP service (harness/src/odsp-service), which takes `storage:<user>` and
        /// `push:<user>` bearer tokens.
        case local(user: String)
    }

    let signIn: SignIn
    let siteUrl: String
    let driveId: String
    /// SharePoint Embedded container type that owns `driveId`.
    let containerType: String

    static let sharePointEmbedded = AppConfig(
        signIn: .microsoft(
            clientId: "<ENTRA_APP_CLIENT_ID>",
            tenantId: "<ENTRA_TENANT_ID>"
        ),
        siteUrl: "https://<TENANT>.sharepoint.com",
        driveId: "<SPE_DRIVE_ID>",
        containerType: "<SPE_CONTAINER_TYPE_ID>"
    )

    /// The local ODSP service started by `npm run odsp-service` in harness/ (server.ts). Its item
    /// ids look like SharePoint's: "01" followed by 32 base32 characters (store.ts `newItemId`).
    /// It has no container types.
    static let local = AppConfig(
        signIn: .local(user: "notes"),
        siteUrl: "http://localhost:7095",
        driveId: "b!bG9jYWwtb2RzcA",
        containerType: ""
    )

    static let active = local
}
