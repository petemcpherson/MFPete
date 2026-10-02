import MFPeteCore
import SwiftUI

/// What a preview is for: plain "Preview Matches", or the Preview button of
/// a bulk guard or apply-to-existing prompt, which answers the prompt here.
struct PreviewTarget: Identifiable {
    enum Mode {
        case matches
        case bulk(BulkApprovalRequest)
        case applyExisting(ApplyExistingRequest)
    }

    let id = UUID()
    var rule: Rule
    var mode: Mode
}

/// Dry run of a rule: each matching file and what each action would do
/// (spec §8.3). Makes no changes.
struct PreviewSheet: View {
    let target: PreviewTarget

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var results: [PlannedFileResult]?

    private var controller: EngineController { appState.engineController }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview: \(target.rule.name)")
                    .font(.title2.bold())
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Group {
                if let results {
                    if results.isEmpty {
                        ContentUnavailableView(
                            "No Matching Files",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Nothing in this rule's folders matches its conditions right now.")
                        )
                    } else {
                        List(results, id: \.file) { PreviewRow(result: $0) }
                            .listStyle(.bordered(alternatesRowBackgrounds: true))
                    }
                } else {
                    ProgressView("Finding matching files…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            Text("Preview makes no changes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 600, height: 460)
        .task { results = await controller.plan(target.rule) }
    }

    private var subtitle: String {
        guard let results else { return String(localized: "Checking the rule's folders…") }
        let processed = results.filter(\.alreadyProcessed).count
        if processed > 0 {
            return String(localized: "\(results.count) matching files, \(processed) already processed")
        }
        return String(localized: "\(results.count) matching files")
    }

    @ViewBuilder
    private var buttons: some View {
        switch target.mode {
        case .matches:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .bulk(let request):
            Button("Cancel Run", role: .cancel) {
                controller.resolveBulk(request, approve: false)
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Run") {
                controller.resolveBulk(request, approve: true)
                dismiss()
            }
        case .applyExisting(let request):
            Button("Apply") {
                controller.resolveApplyExisting(request, apply: true)
                dismiss()
            }
            Button("Only New Files") {
                controller.resolveApplyExisting(request, apply: false)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PreviewRow: View {
    let result: PlannedFileResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.file.lastPathComponent)
            if result.alreadyProcessed {
                Text("Already processed, skipped")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
                Text(Self.text(for: step))
                    .font(.callout)
                    .foregroundStyle(Self.style(for: step.outcome))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func text(for step: PlannedStep) -> String {
        let name = step.action.displayName
        switch step.outcome {
        case .willSucceed:
            guard let destination = step.destination else { return name }
            return "\(name) → " + FolderRef(path: destination.path).tildeAbbreviated()
        case .willSkip(let reason):
            return String(localized: "\(name): skipped (\(reason))")
        case .willFail(let reason):
            return String(localized: "\(name): would fail (\(reason))")
        }
    }

    static func style(for outcome: PlannedStep.Outcome) -> AnyShapeStyle {
        switch outcome {
        case .willSucceed: return AnyShapeStyle(.secondary)
        case .willSkip: return AnyShapeStyle(.orange)
        case .willFail: return AnyShapeStyle(.red)
        }
    }
}
