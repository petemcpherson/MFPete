import AppKit
import MFPeteCore
import SwiftUI

/// Menu bar icon. Also hands the `openWindow` action to `AppState`, because
/// the label is the one view that exists for the whole app lifetime.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let controller = appState.engineController
        Image(nsImage: MenuBarIcon.image(paused: controller.isPaused, badge: controller.hasUnresolvedErrors))
            .accessibilityLabel(Text(accessibilityText))
            .onAppear {
                appState.windowOpener = { id in openWindow(id: id) }
            }
    }

    private var accessibilityText: String {
        let controller = appState.engineController
        if controller.isPaused { return String(localized: "MFPete, paused") }
        if controller.hasUnresolvedErrors { return String(localized: "MFPete, a rule needs attention") }
        return "MFPete"
    }
}

/// Template icon for the status item (spec §8.1): `tray.and.arrow.down`,
/// dimmed when paused, with a dot when a rule has an unresolved error.
enum MenuBarIcon {
    static func image(paused: Bool, badge: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSImage() }

        let dot: CGFloat = 6
        let size = NSSize(width: symbol.size.width + dot / 2, height: symbol.size.height + dot / 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolRect = NSRect(x: 0, y: 0, width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: paused ? 0.4 : 1)
            if paused {
                // Two pause bars in the lower right corner.
                let barWidth: CGFloat = 1.6
                let barHeight: CGFloat = 5
                let originX = rect.maxX - barWidth * 3.2
                NSBezierPath(rect: NSRect(x: originX, y: 0, width: barWidth, height: barHeight)).fill()
                NSBezierPath(rect: NSRect(x: originX + barWidth * 2, y: 0, width: barWidth, height: barHeight)).fill()
            }
            if badge {
                let dotRect = NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)
                // Clear a ring around the dot so it reads against the glyph.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Plain native menu (spec §8.1).
struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var controller: EngineController { appState.engineController }

    var body: some View {
        Text(controller.isPaused
             ? "MFPete — paused"
             : "MFPete — \(appState.activeRuleCount) rules active")

        Divider()

        Section("Recent Activity") {
            if controller.recentActivity.isEmpty {
                Text("No activity yet")
            } else {
                ForEach(controller.recentActivity, id: \.id) { record in
                    Button(record.menuTitle) { reveal(record) }
                }
            }
        }

        Divider()

        Button(controller.isPaused ? "Resume All Rules" : "Pause All Rules") {
            controller.setPaused(!controller.isPaused)
        }
        .keyboardShortcut("p")

        if controller.offerScanAfterResume {
            Button("Scan Files Added While Paused") { controller.scanAfterResume() }
        }

        // All rules, including disabled ones (D14). Feedback comes from the
        // summary notification, since no window is open.
        Menu("Run Rule") {
            if appState.rules.isEmpty {
                Text("No rules")
            }
            ForEach(appState.rules) { rule in
                Button(rule.name) { controller.startRun(rule.id) }
                    .disabled(rule.trigger == .fileRemoved || controller.isRunning(rule.id))
            }
        }

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

    /// Clicking an activity item reveals the file in Finder (spec §8.1).
    private func reveal(_ record: ActivityRecord) {
        let candidates = [record.destinationPath, record.sourcePath].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

extension ActivityRecord {
    /// "Move to Trash: Setup.dmg — 2 hours ago". Failed and skipped entries
    /// get a ✕ or ⚠︎ mark.
    var menuTitle: String {
        let file = URL(fileURLWithPath: sourcePath).lastPathComponent
        let mark: String
        switch result {
        case .success: mark = ""
        case .skipped: mark = "⚠︎ "
        case .failed: mark = "✕ "
        }
        let relative = timestamp.formatted(.relative(presentation: .named))
        return "\(mark)\(action): \(file) — \(relative)"
    }
}
