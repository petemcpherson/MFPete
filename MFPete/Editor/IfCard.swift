import MFPeteCore
import SwiftUI

/// Live match count shown under the conditions.
enum MatchCount: Equatable {
    /// No count possible (no folder yet, or a "File removed" rule).
    case unavailable(String)
    case counting
    case counted(total: Int, alreadyProcessed: Int)
}

/// IF: top-level All/Any, condition rows, and one level of sub-groups (D12).
struct IfCard: View {
    @Binding var rule: Rule
    let matchCount: MatchCount
    let onPreview: () -> Void

    var body: some View {
        EditorCard(title: "IF") {
            HStack(spacing: 6) {
                MatchPicker(match: $rule.conditions.match)
                Text("of the following are true:")
                    .foregroundStyle(.secondary)
            }
            ConditionList(items: $rule.conditions.items, allowsGroups: true)
            HStack(spacing: 12) {
                Button {
                    rule.conditions.items.append(.condition(Attribute.extension.makeCondition()))
                } label: {
                    Label("Add Condition", systemImage: "plus")
                }
                .accessibilityIdentifier("addCondition")
                Button {
                    rule.conditions.items.append(.group(ConditionGroup(
                        match: .any,
                        items: [.condition(Attribute.extension.makeCondition())]
                    )))
                } label: {
                    Label("Add Group", systemImage: "plus.square.on.square")
                }
            }
            .controlSize(.small)

            if RuleValidator.matchesEverything(rule) {
                EditorHint(text: String(localized: "Matches all files in this folder."), style: .warning)
            }
            if RuleValidator.showsAgeHint(rule) {
                EditorHint(text: String(localized: "Age conditions work best on a schedule. A file that was just added is never older than a few seconds."))
            }
            Divider()
            matchCountRow
        }
    }

    @ViewBuilder
    private var matchCountRow: some View {
        HStack(spacing: 8) {
            switch matchCount {
            case .unavailable(let reason):
                Text(reason).foregroundStyle(.secondary)
            case .counting:
                ProgressView().controlSize(.small)
                Text("Counting matching files…").foregroundStyle(.secondary)
            case .counted(let total, let processed):
                Text(Self.countText(total: total, processed: processed))
                    .accessibilityIdentifier("matchCount")
            }
            Spacer()
            Button("Preview", action: onPreview)
                .disabled({ if case .unavailable = matchCount { return true }; return false }())
                .accessibilityIdentifier("editorPreview")
        }
        .font(.callout)
    }

    static func countText(total: Int, processed: Int) -> String {
        if processed > 0 {
            return String(localized: "Matches \(total) files right now (\(processed) already processed)")
        }
        return String(localized: "Matches \(total) files right now")
    }
}

private struct MatchPicker: View {
    @Binding var match: Match

    var body: some View {
        Picker("Match", selection: $match) {
            Text("All").tag(Match.all)
            Text("Any").tag(Match.any)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Rows of one group. Sub-groups are editable only at the top level (D12);
/// deeper groups from imported rules show as a summary row.
private struct ConditionList: View {
    @Binding var items: [ConditionItem]
    let allowsGroups: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                switch item {
                case .condition:
                    ConditionRow(
                        condition: conditionBinding(index),
                        onRemove: { remove(index) },
                        onAdd: { items.insert(.condition(Attribute.extension.makeCondition()), at: index + 1) }
                    )
                case .group(let group):
                    if allowsGroups {
                        GroupRow(group: groupBinding(index, fallback: group), onRemove: { remove(index) })
                    } else {
                        PlaceholderRow(text: String(localized: "Nested group (\(group.items.count) items)"), onRemove: { remove(index) })
                    }
                case .unknown:
                    PlaceholderRow(text: String(localized: "Condition not supported by this version"), onRemove: { remove(index) })
                }
            }
        }
    }

    private func remove(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
    }

    private func conditionBinding(_ index: Int) -> Binding<Condition> {
        Binding(
            get: {
                guard items.indices.contains(index), case .condition(let condition) = items[index] else {
                    return Attribute.anyFile.makeCondition()
                }
                return condition
            },
            set: { newValue in
                guard items.indices.contains(index) else { return }
                items[index] = .condition(newValue)
            }
        )
    }

    private func groupBinding(_ index: Int, fallback: ConditionGroup) -> Binding<ConditionGroup> {
        Binding(
            get: {
                guard items.indices.contains(index), case .group(let group) = items[index] else { return fallback }
                return group
            },
            set: { newValue in
                guard items.indices.contains(index) else { return }
                items[index] = .group(newValue)
            }
        )
    }
}

private struct GroupRow: View {
    @Binding var group: ConditionGroup
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                MatchPicker(match: $group.match)
                Text("of these are true:")
                    .foregroundStyle(.secondary)
                Spacer()
                RowIconButton(systemImage: "minus.circle", label: "Remove group", action: onRemove)
            }
            ConditionList(items: $group.items, allowsGroups: false)
            Button {
                group.items.append(.condition(Attribute.extension.makeCondition()))
            } label: {
                Label("Add Condition", systemImage: "plus")
            }
            .controlSize(.small)
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private struct PlaceholderRow: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            EditorHint(text: text, style: .warning)
            Spacer()
            RowIconButton(systemImage: "minus.circle", label: "Remove condition", action: onRemove)
        }
    }
}

/// Attribute popup → operator popup (filtered by the validity table) →
/// value control by type.
private struct ConditionRow: View {
    @Binding var condition: Condition
    let onRemove: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("Attribute", selection: Binding(
                get: { condition.attribute },
                set: { condition = condition.changingAttribute(to: $0) }
            )) {
                ForEach(Attribute.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Attribute"))

            if condition.attribute != .anyFile {
                Picker("Operator", selection: Binding(
                    get: { condition.op },
                    set: { condition = condition.changingOperator(to: $0) }
                )) {
                    ForEach(condition.attribute.allowedOperators, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text("Operator"))
            }

            ConditionValueField(condition: $condition)
                .frame(maxWidth: .infinity, alignment: .leading)

            RowIconButton(systemImage: "minus.circle", label: "Remove condition", action: onRemove)
            RowIconButton(systemImage: "plus.circle", label: "Add condition below", action: onAdd)
        }
    }
}

private struct ConditionValueField: View {
    @Binding var condition: Condition

    var body: some View {
        switch condition.value {
        case .none:
            Spacer(minLength: 0)
        case .text(let text):
            TextField(placeholder, text: Binding(get: { text }, set: { condition.value = .text($0) }))
                .accessibilityLabel(Text("Value"))
        case .size(let amount, let unit):
            HStack(spacing: 4) {
                TextField("", value: Binding(get: { amount }, set: { condition.value = .size(max(0, $0), unit) }), format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(Text("Size"))
                Picker("Unit", selection: Binding(get: { unit }, set: { condition.value = .size(amount, $0) })) {
                    ForEach(SizeUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .duration(let amount, let unit):
            HStack(spacing: 4) {
                NumberField(value: Binding(get: { amount }, set: { condition.value = .duration($0, unit) }))
                    .accessibilityLabel(Text("Amount"))
                Picker("Unit", selection: Binding(get: { unit }, set: { condition.value = .duration(amount, $0) })) {
                    ForEach(DurationUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .date(let date):
            DatePicker("Date", selection: Binding(get: { date }, set: { condition.value = .date($0) }), displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
        case .kind(let kind):
            Picker("Kind", selection: Binding(get: { kind }, set: { condition.value = .kind($0) })) {
                ForEach(FileKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .tags(let tags):
            CommaListField(placeholder: "Tag names, comma separated", items: Binding(get: { tags }, set: { condition.value = .tags($0) }))
                .accessibilityLabel(Text("Tags"))
        }
    }

    private var placeholder: LocalizedStringKey {
        switch (condition.attribute, condition.op) {
        case (.extension, .isAnyOf): return "dmg, zip"
        case (.extension, _): return "pdf"
        case (_, .matchesPattern): return "Screenshot*"
        case (.downloadedFrom, _): return "example.com"
        default: return "Text"
        }
    }
}
