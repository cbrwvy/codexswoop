import Darwin
import Foundation

/// Read-only installation evidence. Deliberately not a DesktopInstanceInventory or a
/// lifecycle capability; never use it to settle a pending opening/quit operation.
public struct InstallationProcessPreflightReport: Equatable, Sendable {
    public let activeInstances: Int
    public let confirmedZombieCount: Int
    public let referenceCount: Int
    public let historicalAliasCount: Int
    public let referenceGroupIndices: [Int]
    public let mainGenerationCount: Int
    public let backendGenerationCount: Int
    private let entries: [DesktopInventoryEntry]
    private let tombstones: [Int32: InstallationZombieWitness]
    private let samples: [InstallationGroupingSnapshot]

    init(entries: [DesktopInventoryEntry], witnesses: [Int32: InstallationZombieWitness]) {
        self.entries = entries; tombstones = witnesses
        activeInstances = entries.count; confirmedZombieCount = witnesses.count
        referenceCount = entries.count; historicalAliasCount = 0
        referenceGroupIndices = Array(entries.indices); samples = []
        mainGenerationCount = entries.count; backendGenerationCount = 0
    }

    init(first: InstallationGroupingSnapshot, second: InstallationGroupingSnapshot) throws {
        guard first == second else { throw EnvironmentError.processChanged }
        // Both raw observations/provenance are retained. Equality permits only positive
        // descriptor-count fluctuations, never generation, ancestry or membership drift.
        samples = [first, second]; entries = []; tombstones = second.witnesses
        activeInstances = second.groups.filter { $0.instance != nil }.count
        confirmedZombieCount = second.witnesses.count
        referenceCount = second.references.values.count
        mainGenerationCount = second.mains.count
        backendGenerationCount = second.observations.first?.before.filter { $0.role == .backend }.count ?? 0
        historicalAliasCount = second.groups.reduce(0) { $0 + max(0, $1.referenceIndices.count - 1) }
        var indices = Array(repeating: -1, count: referenceCount)
        for (group, value) in second.groups.enumerated() {
            for reference in value.referenceIndices { indices[reference] = group }
        }
        referenceGroupIndices = indices
    }
}

/// Kernel metadata only, with no command arguments, environment, or executable paths.
struct KernelProcessStatus: Equatable, Sendable {
    let pid: Int32, parent: Int32, uid: UInt32, status: Int32
    let seconds: Int64, microseconds: Int64

    static func read(_ pid: Int32) throws -> Self {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var record = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &record, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else { throw EnvironmentError.processChanged }
        return Self(pid: record.kp_proc.p_pid, parent: record.kp_eproc.e_ppid,
            uid: record.kp_eproc.e_ucred.cr_uid, status: Int32(record.kp_proc.p_stat),
            seconds: Int64(record.kp_proc.p_starttime.tv_sec),
            microseconds: Int64(record.kp_proc.p_starttime.tv_usec))
    }
}

/// A terminal leaf is eligible only in the explicitly read-only installation path.
/// ps state is corroboration, not an independent kernel API: ps itself uses sysctl.
struct InstallationZombieWitness: Equatable, Sendable {
    let kernel: KernelProcessStatus
    let parent: DesktopGeneration

    static func confirm(metadata: DesktopProcessMetadata, psStatus: String,
        first: KernelProcessStatus, second: KernelProcessStatus,
        parent: DesktopGeneration, hasChildren: Bool) throws -> Self {
        guard psStatus.first == "Z", first == second, first.status == SZOMB,
              first.pid == metadata.pid, first.parent == metadata.parent,
              first.uid == metadata.uid, first.uid == getuid(), first.pid > 0,
              first.parent > 0, first.parent != first.pid, !hasChildren,
              first.seconds > 0, first.seconds < Int64.max / 1_000_000,
              (0..<1_000_000).contains(first.microseconds),
              parent.pid == first.parent, parent.uid == first.uid,
              let parentStart = parent.startTimeMicroseconds,
              parentStart <= UInt64(first.seconds * 1_000_000 + first.microseconds) else {
            throw EnvironmentError.processChanged
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard formatter.string(from: Date(timeIntervalSince1970: Double(first.seconds))) == metadata.started else {
            throw EnvironmentError.processChanged
        }
        return Self(kernel: first, parent: parent)
    }
}

enum InstallationProcessSample {
    case active(DesktopGeneration), zombie(InstallationZombieWitness)

    static func read(metadata: DesktopProcessMetadata, psStatus: String, hasChildren: Bool,
        parent: () throws -> DesktopGeneration,
        kernel: (Int32) throws -> KernelProcessStatus = KernelProcessStatus.read,
        precise: (DesktopProcessMetadata) throws -> DesktopGeneration = { try $0.preciseGeneration() }) throws -> Self {
        if psStatus.first == "Z" {
            let first = try kernel(metadata.pid), parentGeneration = try parent()
            let second = try kernel(metadata.pid)
            return .zombie(try InstallationZombieWitness.confirm(metadata: metadata,
                psStatus: psStatus, first: first, second: second, parent: parentGeneration,
                hasChildren: hasChildren))
        }
        let generation = try precise(metadata)
        guard generation.pid == metadata.pid, generation.uid == metadata.uid,
              generation.started == metadata.started, generation.startTimeMicroseconds != nil else {
            throw EnvironmentError.processChanged
        }
        return .active(generation)
    }
}

/// One session inside the existing NativeDesktopSystem inventory. Every sample must
/// retain the exact terminal and parent generations; disappearance also fails closed.
final class InstallationPreflightSession {
    private(set) var witnesses: [Int32: InstallationZombieWitness]?
    var observations: [InstallationReferenceObservation] = []
    func check(_ current: [Int32: InstallationZombieWitness]) throws {
        if let witnesses, witnesses != current { throw EnvironmentError.processChanged }
        witnesses = current
    }
}
