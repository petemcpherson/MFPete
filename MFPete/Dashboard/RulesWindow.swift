import MFPeteCore
import SwiftUI

/// Placeholder Rules window. The full dashboard (summaries, search, filter,
/// sort, row menu) comes in Phase 4.
struct RulesWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            ForEach(appState.rules) { rule in
                Toggle(isOn: enabledBinding(for: rule)) {
                    Text(rule.name)
                }
                .toggleStyle(.switch)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        appState.delete([rule.id])
                    }
                }
            }
            .onMove { source, destination in
                appState.move(fromOffsets: source, toOffset: destination)
            }
        }
        .overlay {
            if appState.rules.isEmpty {
                ContentUnavailableView(
                    "No Rules Yet",
                    systemImage: "tray.and.arrow.down",
                    description: Text("Rules you create appear here.")
                )
            }
        }
        .toolbar {
            Button {
                appState.add(Rule(isEnabled: false))
            } label: {
                Label("New Rule", systemImage: "plus")
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func enabledBinding(for rule: Rule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { appState.setEnabled($0, for: rule.id) }
        )
    }
}
