import MFPeteCore
import SwiftUI

/// WHEN: the trigger, the folders it watches, and scope options (spec §8.3).
struct WhenCard: View {
    @Binding var rule: Rule
    @State private var showsOptions = false

    @Environment(FolderGate.self) private var gate

    var body: some View {
        EditorCard(title: "WHEN") {
            HStack(spacing: 8) {
                Picker("Trigger", selection: triggerType) {
                    ForEach(TriggerType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("triggerPicker")
                Text(rule.trigger.isFileEvent ? "in" : "scan")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScheduleControls(trigger: $rule.trigger)

            folders

            DisclosureGroup("Options", isExpanded: $showsOptions) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Include subfolders", isOn: $rule.options.includeSubfolders)
                    Toggle("Include hidden files", isOn: $rule.options.includeHidden)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .onAppear {
            showsOptions = rule.options.includeSubfolders || rule.options.includeHidden
        }
    }

    private var triggerType: Binding<TriggerType> {
        Binding(
            get: { rule.trigger.type },
            set: { rule.trigger = $0.makeTrigger(from: rule.trigger) }
        )
    }

    @ViewBuilder
    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rule.scope.enumerated()), id: \.offset) { index, folder in
                HStack(spacing: 6) {
                    FolderField(folder: folder) { chosen in
                        guard rule.scope.indices.contains(index) else { return }
                        rule.scope[index] = chosen
                    }
                    RowIconButton(systemImage: "minus.circle", label: "Remove folder") {
                        rule.scope.remove(at: index)
                    }
                }
            }
            Button {
                gate.chooseFolder(startingAt: nil) { addFolder($0) }
            } label: {
                Label("Add Folder", systemImage: "plus")
            }
            .controlSize(.small)
            .accessibilityIdentifier("addFolder")
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || FolderGate.isDirectory($0) }
            for url in folders {
                gate.accept(url) { addFolder($0) }
            }
            return !folders.isEmpty
        }
    }

    private func addFolder(_ folder: FolderRef) {
        // A template's empty placeholder is replaced by the first real folder.
        if let empty = rule.scope.firstIndex(where: { $0.path.isEmpty }) {
            rule.scope[empty] = folder
        } else if !rule.scope.contains(folder) {
            rule.scope.append(folder)
        }
    }
}

/// Interval, daily time, or weekday + time controls for schedule triggers.
private struct ScheduleControls: View {
    @Binding var trigger: Trigger
    @State private var usesHours = false

    var body: some View {
        switch trigger {
        case .interval(let minutes):
            HStack(spacing: 6) {
                Text("Every")
                NumberField(value: intervalAmount(minutes), minimum: 1)
                Picker("Unit", selection: unitBinding(minutes)) {
                    Text("minutes").tag(false)
                    Text("hours").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                if minutes < Trigger.minimumIntervalMinutes {
                    EditorHint(text: String(localized: "Minimum is 5 minutes."), style: .error)
                }
            }
            .onAppear { usesHours = minutes >= 60 && minutes % 60 == 0 }
        case .daily(let hour, let minute, let days):
            HStack(spacing: 6) {
                Text("Every")
                NumberField(value: Binding(
                    get: { days },
                    set: { trigger = .daily(hour: hour, minute: minute, days: $0) }
                ), minimum: 1)
                .accessibilityIdentifier("dailyDays")
                Text(days == 1 ? "day at" : "days at")
                timePicker(hour: hour, minute: minute) { trigger = .daily(hour: $0, minute: $1, days: days) }
            }
        case .weekly(let weekdays, let hour, let minute):
            VStack(alignment: .leading, spacing: 6) {
                WeekdayPicker(weekdays: Binding(
                    get: { weekdays },
                    set: { trigger = .weekly(weekdays: $0, hour: hour, minute: minute) }
                ))
                HStack(spacing: 6) {
                    Text("At")
                    timePicker(hour: hour, minute: minute) { trigger = .weekly(weekdays: weekdays, hour: $0, minute: $1) }
                }
            }
        case .fileAdded, .fileModified, .fileRemoved:
            EmptyView()
        }
    }

    private func intervalAmount(_ minutes: Int) -> Binding<Int> {
        Binding(
            get: { usesHours ? max(1, minutes / 60) : minutes },
            set: { trigger = .interval(minutes: usesHours ? $0 * 60 : $0) }
        )
    }

    private func unitBinding(_ minutes: Int) -> Binding<Bool> {
        Binding(
            get: { usesHours },
            set: { hours in
                guard hours != usesHours else { return }
                usesHours = hours
                // Keep the number the user sees; change only the unit.
                trigger = .interval(minutes: hours ? minutes * 60 : max(1, minutes / 60))
            }
        )
    }

    private func timePicker(hour: Int, minute: Int, set: @escaping (Int, Int) -> Void) -> some View {
        let calendar = Calendar.current
        let date = Binding<Date>(
            get: { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = calendar.dateComponents([.hour, .minute], from: $0)
                set(parts.hour ?? 0, parts.minute ?? 0)
            }
        )
        return DatePicker("Time", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
    }
}

/// Seven toggle buttons, Calendar weekday numbering (1 = Sunday), shown in
/// the user's first-weekday order.
private struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let names = calendar.standaloneWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                Toggle(isOn: Binding(
                    get: { weekdays.contains(day) },
                    set: { on in
                        if on { weekdays.insert(day) } else { weekdays.remove(day) }
                    }
                )) {
                    Text(symbols[day - 1]).frame(width: 18)
                }
                .toggleStyle(.button)
                .accessibilityLabel(Text(names[day - 1]))
            }
            if weekdays.isEmpty {
                EditorHint(text: String(localized: "Pick at least one day."), style: .error)
            }
        }
    }
}
