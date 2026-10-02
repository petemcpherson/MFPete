import AppKit
import SwiftUI

/// One-time hint after onboarding that points at the menu bar icon
/// (spec §8.7). `MenuBarExtra` exposes no anchor, so this finds the status
/// item's window and shows a small borderless panel under it. Closes on
/// click or after a few seconds.
@MainActor
enum MenuBarHint {
    private static var panel: NSPanel?
    private static let visibleSeconds: Double = 8

    static func showSoon() {
        guard !UITestingFixture.isActive else { return }
        // Let the onboarding window close first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { show() }
    }

    static func show() {
        guard panel == nil, let anchor = statusItemFrame() else { return }

        let hosting = NSHostingView(rootView: HintView { close() })
        hosting.setFrameSize(hosting.fittingSize)
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + visibleSeconds) { close() }
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// The menu bar extra lives in an `NSStatusBarWindow`.
    private static func statusItemFrame() -> NSRect? {
        NSApp.windows
            .first { String(describing: type(of: $0)).contains("NSStatusBarWindow") && $0.isVisible }?
            .frame
    }
}

private struct HintView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 12))
                .foregroundStyle(.regularMaterial)
                .offset(y: 3)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MFPete lives here")
                        .font(.headline)
                    Text("Click the icon to open your rules, run one now, or pause everything.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
