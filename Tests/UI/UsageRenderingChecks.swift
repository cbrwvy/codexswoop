import AppKit
import SwiftUI
import CodexSwoopCore

/// Offscreen-only synthetic rendering. No NSWindow, activation, ProfileManager or real metadata.
@main struct UsageRenderingChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_791_800_000)
        func snapshot(weeklyOnly: Bool = false) throws -> AccountUsageSnapshot {
            let id = UUID()
            let identity: [String: Any] = ["device": 1, "inode": 10, "owner": 501, "permissions": 448]
            let raw: [String: Any] = ["profileID": id.uuidString, "environmentID": UUID().uuidString,
                "kind": "managed", "codexHome": "/fictional/home", "electronData": "/fictional/electron",
                "homeIdentity": identity, "electronIdentity": identity, "origin": "userSelected",
                "lastCheck": "directoryMetadataVerified", "checkedAt": date.timeIntervalSinceReferenceDate]
            let association = try JSONDecoder().decode(EnvironmentAssociation.self, from: JSONSerialization.data(withJSONObject: raw))
            let gen = DesktopGeneration(pid: 123456, uid: 501, started: "fictional-render-only")
            let key = try AccountIdentityKey(namespace: "fictional", subject: "render-only")
            let context = UsageContext(association: association, instance: DesktopInstance(main: gen, related: [gen], nativeLaunchDate: date), accountIdentity: key, accountScope: key, transportID: UUID())
            let five = try UsageWindow(usedPercent: 28.125, durationMinutes: 300, resetsAt: date.addingTimeInterval(3600), observedAt: date)
            let weekly = try UsageWindow(usedPercent: 59, durationMinutes: 10080, resetsAt: nil, observedAt: date)
            let buckets = [UsageBucket(limitID: "codex", primary: weeklyOnly ? nil : five, secondary: weekly, plan: "plus")]
            return AccountUsageSnapshot(context: context, data: DecodedUsage(accountScope: key, buckets: buckets), updatedAt: date)
        }
        var cases: [(String, UsageViewState)] = []
        for status in UsageStatus.allCases {
            let values = [.available, .refreshing, .stale].contains(status) ? try snapshot() : nil
            cases.append((status.rawValue.replacingOccurrences(of: " ", with: "-"), UsageViewState(status: status, snapshot: values, explanation: status == .verificationRequired ? UsageIntegrationPolicy.blockedReason : "Fictional UI fixture · \(status.rawValue)", canRefresh: status == .available || status == .error)))
        }
        cases.append(("weekly-only", UsageViewState(status: .available, snapshot: try snapshot(weeklyOnly: true), explanation: "Fictional weekly-only fixture", canRefresh: true)))
        var rendered = 0
        for language in [AppLanguage.english, .russian, .uzbek] {
        L10n.setSessionLanguage(language)
        for (name, state) in cases {
            for scheme in [ColorScheme.light, .dark] {
                for width in [240.0, 308.0] {
                    let view = VStack(alignment: .leading, spacing: 8) {
                        Text("FICTIONAL DATA · UI CHECK").font(.caption2).foregroundStyle(.secondary)
                        Text("Fictional Personal").lineLimit(1).truncationMode(.middle)
                        AccountUsageView(state: state) {}
                        Divider()
                        Text(String(repeating: "Long fictional account name ", count: 5)).lineLimit(1).truncationMode(.middle)
                        AccountUsageView(state: UsageViewState(status: .verificationRequired, explanation: UsageIntegrationPolicy.blockedReason)) {}
                    }.padding(12).frame(width: width).background(scheme == .dark ? Color(nsColor: .darkGray) : Color(nsColor: .white))
                        .environment(\.colorScheme, scheme)
                    NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSApplication.shared.appearance
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    let size = host.fittingSize
                    guard size.width <= width + 1, size.height > 60, size.height < 1100 else { fatalError("Invalid synthetic layout: \(size)") }
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No offscreen bitmap") }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]), png.count > 1000 else { fatalError("Blank rendering") }
                    try png.write(to: output.appendingPathComponent("\(language.rawValue)-\(name)-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"))
                    rendered += 1
                }
            }
        }
        }
        print("PASS \(rendered) offscreen Usage renders: all ten states, two profiles, one/two windows, long name, narrow/normal width, Light/Dark. No windows created or activated.")
    }
}
