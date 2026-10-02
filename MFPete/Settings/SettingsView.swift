import SwiftUI

/// Settings scene (spec §8.5). Tabs are filled in Phase 6.
struct SettingsView: View {
    var body: some View {
        TabView {
            placeholder("General settings will appear here.")
                .tabItem { Label("General", systemImage: "gearshape") }
            placeholder("Folders used by your rules will appear here.")
                .tabItem { Label("Folders", systemImage: "folder") }
            placeholder("Advanced settings will appear here.")
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            placeholder("MFPete is free and open source (MIT).")
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 260)
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
