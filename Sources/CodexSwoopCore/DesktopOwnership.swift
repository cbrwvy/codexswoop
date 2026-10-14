import Foundation
import Darwin

/// Normalized, non-secret snapshot. Counts describe open descriptors, never file contents.
public struct DesktopProcessEvidence: Equatable, Sendable {
    public enum Role: Sendable { case main, backend, helper, external }
    public let generation: DesktopGeneration
    public let parent: Int32
    public let role: Role
    public let homeDescriptors: Int
    public let electronDescriptors: Int
    public let defaultDescriptors: Int
    public init(generation: DesktopGeneration, parent: Int32, role: Role,
                homeDescriptors: Int = 0, electronDescriptors: Int = 0, defaultDescriptors: Int = 0) {
        self.generation = generation; self.parent = parent; self.role = role
        self.homeDescriptors = homeDescriptors; self.electronDescriptors = electronDescriptors
        self.defaultDescriptors = defaultDescriptors
    }
}

public enum DesktopOwnership {
    /// Positive directory evidence plus stable ancestry is necessary, but does not prove account identity
    /// or absence of detached/shared work. Missing or contradictory evidence fails closed.
    public static func resolve(before: [DesktopProcessEvidence], after: [DesktopProcessEvidence],
                               standard: Bool) throws -> [[DesktopGeneration]] {
        guard Set(before.map { $0.generation.pid }).count == before.count,
              Set(after.map { $0.generation.pid }).count == after.count else { throw EnvironmentError.ambiguousInstance }
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.generation.pid, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.map { ($0.generation.pid, $0) })
        func lineage(_ rows: [Int32: DesktopProcessEvidence], _ main: Int32) -> Set<Int32> {
            var members: Set<Int32> = [main]
            while true {
                let next = members.union(rows.values.filter { members.contains($0.parent) }.map { $0.generation.pid })
                if next == members { return members }; members = next
            }
        }
        func uses(_ row: DesktopProcessEvidence) -> Bool { row.homeDescriptors > 0 || row.electronDescriptors > 0 }
        // Counts may change between samples; identity, role and ancestry may not.
        func same(_ a: DesktopProcessEvidence, _ b: DesktopProcessEvidence?) -> Bool {
            guard let b else { return false }
            return a.generation == b.generation && a.parent == b.parent && a.role == b.role
        }
        guard before.filter({ $0.role != .external }).allSatisfy({ same($0, new[$0.generation.pid]) }) else {
            throw EnvironmentError.processChanged
        }
        var result: [[DesktopGeneration]] = [], attributed = Set<Int32>()
        for main in before where main.role == .main {
            let members = lineage(old, main.generation.pid)
            guard members.contains(where: { old[$0].map(uses) ?? false }) else { continue }
            // The GUI owns Electron storage; its direct backend owns CODEX_HOME. The GUI
            // need not retain a home FD after a short read or a failed IPC socket bind.
            // Both roots still require positive descriptors in one stable, exclusive lineage.
            guard main.electronDescriptors > 0,
                  before.contains(where: { $0.parent == main.generation.pid && $0.role == .backend && $0.homeDescriptors > 0 }),
                  members.allSatisfy({ pid in
                      guard let row = old[pid] else { return false }
                      return row.generation.pid > 0 && row.generation.uid == getuid() && !row.generation.started.isEmpty
                          && same(row, new[pid]) && (standard || row.defaultDescriptors == 0)
                  }), lineage(new, main.generation.pid) == members else { throw EnvironmentError.ambiguousInstance }
            result.append(members.sorted().compactMap { old[$0]?.generation })
            attributed.formUnion(members)
        }
        guard result.count <= 1, !before.contains(where: { uses($0) && !attributed.contains($0.generation.pid) }) else {
            throw EnvironmentError.ambiguousInstance
        }
        return result
    }
}
