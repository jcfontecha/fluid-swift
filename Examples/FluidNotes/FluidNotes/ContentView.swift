import Fluid
import SwiftUI

struct ContentView: View {
    @State private var model = NotesModel(config: .active)
    @State private var isEnteringItem = false
    @State private var itemId = ""

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    if model.isSignedIn {
                        ToolbarItem(placement: .topBarLeading) {
                            ConnectionIndicator(status: model.isOpening ? .connecting : model.container?.status)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Open", systemImage: "doc") {
                                isEnteringItem = true
                            }
                        }
                    }
                }
                .toolbarTitleDisplayMode(.inline)
        }
        .tint(.primary)
        .sheet(isPresented: $isEnteringItem) {
            ItemField(itemId: $itemId) {
                isEnteringItem = false
                Task { await model.open(itemId: itemId) }
            }
            .presentationDetents([.height(88)])
        }
        .alert(model.failure ?? "", isPresented: hasFailure) {}
        .onChange(of: model.closeFailure) {
            if let closeFailure = model.closeFailure {
                model.failure = closeFailure
            }
        }
        .onChange(of: model.isSignedIn, initial: true) {
            if model.isSignedIn && model.note == nil {
                isEnteringItem = true
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.isSignedIn {
            Button("Sign in with Microsoft") {
                Task { await model.signIn() }
            }
            .buttonStyle(.bordered)
        } else if let note = model.note {
            NoteEditor(note: note)
                .id(ObjectIdentifier(note))
        }
    }

    private var hasFailure: Binding<Bool> {
        Binding {
            model.failure != nil
        } set: { presented in
            if !presented {
                model.failure = nil
            }
        }
    }
}

private struct ConnectionIndicator: View {
    let status: ContainerStatus?

    var body: some View {
        switch status {
        case .connecting:
            ProgressView()
        case .connected:
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .accessibilityLabel("Connected")
        case .disconnected, .closed:
            Image(systemName: "circle")
                .imageScale(.small)
                .accessibilityLabel("Disconnected")
        case nil:
            EmptyView()
        }
    }
}

private struct ItemField: View {
    @Binding var itemId: String
    let open: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Item ID", text: $itemId)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .focused($focused)
            .onSubmit {
                if !itemId.isEmpty {
                    open()
                }
            }
            .padding()
            .onAppear { focused = true }
    }
}
