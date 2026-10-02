import SwiftUI

/// Menu bar icon. Also hands the `openWindow` action to `AppState`, because
/// the label is the one view that exists for the whole app lifetime.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "tray.and.arrow.down")
            .accessibilityLabel(Text("MFPete"))
            .onAppear {
                appState.windowOpener = { id in openWindow(id: id) }
            }
    }
}

/// Plain native menu (spec §8.1). Recent activity, pause, and the Run rule
/// submenu come in Phase 4.
struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("MFPete — \(appState.activeRuleCount) rules active")

        Divider()

        Button("Open Rules…") {
            openWindow(id: WindowID.rules)
            AppActivation.bringToFront()
        }
        .keyboardShortcut("r")

        Button("Settings…") {
            openSettings()
            AppActivation.bringToFront()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit MFPete") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
