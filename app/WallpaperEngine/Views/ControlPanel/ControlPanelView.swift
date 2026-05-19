import Combine
import SwiftUI

enum SidebarSelection: String, CaseIterable, Identifiable {
    case wallpaper
    case display
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .wallpaper: "Wallpaper"
        case .display: "Display"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .wallpaper: "photo.on.rectangle"
        case .display: "display.2"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
    @Published var selection: SidebarSelection?

    init(selection: SidebarSelection? = .wallpaper) {
        self.selection = selection
    }
}

struct ControlPanelView: View {
    let store: BridgeStore
    @ObservedObject private var navigation: ControlPanelNavigation
    @State private var presentedError: ControlPanelError?

    init(store: BridgeStore, navigation: ControlPanelNavigation) {
        self.store = store
        self.navigation = navigation
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSelection.allCases, selection: $navigation.selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle("Wallpaper Engine")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            switch navigation.selection {
            case .wallpaper, .none:
                WallpaperPageView()
            case .display:
                DisplayInformationView()
            case .settings:
                SettingsView()
            }
        } detail: {
            if navigation.selection == .wallpaper || navigation.selection == nil {
                WallpaperInspectorView()
            } else {
                EmptyView()
            }
        }
        .environment(store)
        .frame(minWidth: 980, minHeight: 640)
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .onChange(of: store.latestBridgeErrorRevision) { _, _ in
            guard let message = store.latestBridgeErrorMessage else {
                return
            }
            presentedError = ControlPanelError(message: message)
        }
        .task {
            do {
                try await store.refreshAllAsync()
            } catch {
                presentedError = ControlPanelError(error: error)
            }
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("Bridge Error"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct ControlPanelError: Identifiable {
    let id = UUID()
    let message: String

    init(error: Error) {
        self.message = error.localizedDescription
    }

    init(message: String) {
        self.message = message
    }
}
