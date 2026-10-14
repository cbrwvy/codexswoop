import SwiftUI
import CodexSwoopCore

struct AccountUsageView: View {
    let state: UsageViewState
    let refresh: () -> Void
    private let coral = Color(red: 1, green: 90.0 / 255, blue: 54.0 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L10n.text("usage.title")).font(.caption2).foregroundStyle(.secondary)
                if state.status != .available {
                    Text(state.status.localizedTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help(state.explanation)
                }
                Spacer(minLength: 0)
                if state.status == .loading || state.status == .refreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel(state.status.localizedTitle)
                }
                Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.caption2) }
                    .buttonStyle(.plain).disabled(!state.canRefresh)
                    .help(state.canRefresh ? L10n.text("usage.refreshHelp") : state.explanation)
                    .accessibilityLabel(L10n.text("usage.refresh")).accessibilityHint(state.explanation)
            }
            if let snapshot = state.snapshot {
                if let core = snapshot.data.buckets.first(where: { $0.limitID == "codex" }) {
                    bucket(core)
                }
                let additional = snapshot.data.buckets.filter { $0.limitID != "codex" }
                if !additional.isEmpty {
                    DisclosureGroup(L10n.text("usage.more", additional.count)) {
                        ForEach(additional, id: \.limitID) { value in
                            Text(value.title).font(.caption2).lineLimit(1).help(value.title)
                            bucket(value)
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                if state.status != .available && state.status != .refreshing {
                    Text(state.explanation).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(state.explanation).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let updatedAt = state.lastSuccessfulUpdate {
                Text(L10n.text("usage.updated", updatedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(L10n.text("usage.lastUpdate", updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale))))
            }
        }
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func bucket(_ value: UsageBucket) -> some View {
        if let plan = value.plan { Text(plan.capitalized).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(plan) }
        if value.windows.isEmpty { Text(L10n.text("usage.noWindows")).font(.caption2).foregroundStyle(.secondary) }
        ForEach(Array(value.windows.enumerated()), id: \.offset) { _, window in
            HStack(spacing: 7) {
                Text(window.title).font(.caption2).frame(width: 55, alignment: .leading).lineLimit(1).help(window.title)
                ProgressView(value: window.remainingPercent, total: 100)
                    .tint(state.status == .available ? coral : Color.secondary).controlSize(.mini)
                    .accessibilityHidden(true)
                Text(window.remainingText).font(.caption2).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(value.title), \(window.title), \(window.remainingText). \(resetText(window))")
            .help(resetText(window))
        }
    }
    private func resetText(_ window: UsageWindow) -> String {
        window.resetsAt.map { L10n.text("usage.resets", $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) } ?? L10n.text("usage.noReset")
    }
}
