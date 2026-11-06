import MSAL
import SwiftUI

@main
struct FluidNotesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Returns the Microsoft Authenticator broker response to MSAL.
                    MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
                }
        }
    }
}
