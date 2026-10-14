import Darwin
import Foundation

// Installation-only evidence. None of these types is a lifecycle/recovery capability.
enum InstallationReferenceSource: Equatable, Sendable {
    case current, retained, researchBackup, managedRegistry
}

struct InstallationAssociationReference: Equatable, Sendable {
    let association: EnvironmentAssociation
    var sources: [InstallationReferenceSource]
}

struct InstallationAssociationReferences: Equatable, Sendable {
    let state: AccountSetupState
    let research: [EnvironmentAssociation]
    let values: [InstallationAssociationReference]

    init(state: AccountSetupState, research: [EnvironmentAssociation]) throws {
        try state.profiles.validate(); try state.associations.validate()
        try state.managed.validate(); try state.retained.validate()
        let profiles = Set(state.profiles.profiles.map(\.id))
        guard Set(state.associations.associations.map(\.profileID)).isSubset(of: profiles),
              Set(state.managed.prepared.map(\.profileID)).isSubset(of: profiles),
              research.allSatisfy({ $0.isTemporary && profiles.contains($0.profileID) }) else {
            throw EnvironmentError.invalidMetadata
        }
        var values: [InstallationAssociationReference] = []
        func append(_ association: EnvironmentAssociation, _ source: InstallationReferenceSource) throws {
            if let index = values.firstIndex(where: { $0.association.environmentID == association.environmentID }) {
                // Exact duplicate source occurrences are retained; conflicting IDs never disappear.
                guard values[index].association == association else { throw EnvironmentError.invalidMetadata }
                values[index].sources.append(source)
            } else {
                values.append(InstallationAssociationReference(association: association, sources: [source]))
            }
        }
        for association in state.associations.associations { try append(association, .current) }
        for association in research { try append(association, .researchBackup) }
        for retained in state.retained.environments { try append(retained.association, .retained) }
        for association in state.managed.prepared { try append(association, .managedRegistry) }
        self.state = state; self.research = research; self.values = values
    }

    func revalidate(using validator: EnvironmentValidator) throws {
        for reference in values { try validator.revalidate(reference.association) }
    }
}

/// Keeps original descriptor counts in RAM. Stability concerns exact identity, role,
/// ancestry and positive root evidence, not count fluctuations or dictionary order.
struct InstallationReferenceObservation: Equatable, Sendable {
    let association: EnvironmentAssociation
    let instance: DesktopInstance?
    let before: [DesktopProcessEvidence]
    let after: [DesktopProcessEvidence]

    init(association: EnvironmentAssociation, instance: DesktopInstance?,
         before: [DesktopProcessEvidence], after: [DesktopProcessEvidence]) {
        self.association = association; self.instance = instance
        func selected(_ rows: [DesktopProcessEvidence]) -> [DesktopProcessEvidence] {
            var members = Set(rows.filter { $0.role != .external }.map { $0.generation.pid })
            while true {
                let expanded = members.union(rows.filter { members.contains($0.parent) }.map { $0.generation.pid })
                if expanded == members { break }; members = expanded
            }
            return rows.filter { members.contains($0.generation.pid) }.sorted { $0.generation.pid < $1.generation.pid }
        }
        self.before = selected(before); self.after = selected(after)
    }

    private static func stable(_ lhs: [DesktopProcessEvidence], _ rhs: [DesktopProcessEvidence]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.generation == $1.generation && $0.parent == $1.parent && $0.role == $1.role
                && ($0.homeDescriptors > 0) == ($1.homeDescriptors > 0)
                && ($0.electronDescriptors > 0) == ($1.electronDescriptors > 0)
                && ($0.defaultDescriptors > 0) == ($1.defaultDescriptors > 0)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.association == rhs.association && lhs.instance == rhs.instance
            && stable(lhs.before, rhs.before) && stable(lhs.after, rhs.after)
    }

    func validate() throws {
        // Reuse the exact resolver, including incomplete/unattributed descriptors and ancestry.
        let resolved = try DesktopOwnership.resolve(before: before, after: after,
            standard: association.kind == .standardExternal)
        guard before.allSatisfy({ $0.generation.startTimeMicroseconds != nil }),
              after.allSatisfy({ $0.generation.startTimeMicroseconds != nil }),
              resolved == (instance.map({ [$0.related] }) ?? []),
              instance == (try DesktopObservation(matching: instance.map { [$0] } ?? [], ambiguous: false).unique()) else {
            throw EnvironmentError.processChanged
        }
    }
}

struct InstallationEnvironmentGroup: Equatable, Sendable {
    let referenceIndices: [Int]
    let ownerIndex: Int?
    let instance: DesktopInstance?
}

struct InstallationGroupingSnapshot: Equatable, Sendable {
    let references: InstallationAssociationReferences
    let observations: [InstallationReferenceObservation]
    let groups: [InstallationEnvironmentGroup]
    let mains: Set<DesktopGeneration>
    let nativePIDs: Set<Int32>
    let witnesses: [Int32: InstallationZombieWitness]
    let build: OpeningBuildFingerprint

    // Called only after the native adapter freshly revalidates every directory before
    // and after observation. This pure validator is also exercised by synthetic fixtures.
    init(references: InstallationAssociationReferences, observations: [InstallationReferenceObservation],
         mains: Set<DesktopGeneration>, nativePIDs: Set<Int32>,
         witnesses: [Int32: InstallationZombieWitness], build: OpeningBuildFingerprint) throws {
        try build.validate()
        guard observations.count == references.values.count,
              Set(mains.map(\.pid)).count == mains.count,
              mains.allSatisfy({ $0.startTimeMicroseconds != nil }),
              Set(mains.map(\.pid)).isSubset(of: nativePIDs) else { throw EnvironmentError.processChanged }
        for (reference, observation) in zip(references.values, observations) {
            guard reference.association == observation.association else { throw EnvironmentError.invalidMetadata }
            try observation.validate()
        }
        func exactPair(_ a: EnvironmentAssociation, _ b: EnvironmentAssociation) -> Bool {
            a.codexHome == b.codexHome && a.electronData == b.electronData
                && a.homeIdentity == b.homeIdentity && a.electronIdentity == b.electronIdentity
        }
        func overlap(_ a: EnvironmentAssociation, _ b: EnvironmentAssociation) -> Bool {
            let left = [(a.codexHome, a.homeIdentity), (a.electronData, a.electronIdentity)]
            let right = [(b.codexHome, b.homeIdentity), (b.electronData, b.electronIdentity)]
            return left.contains { x in right.contains { y in
                (x.1.device == y.1.device && x.1.inode == y.1.inode)
                    || EnvironmentValidator.overlaps(x.0, y.0)
            } }
        }
        var buckets: [[Int]] = []
        for i in references.values.indices {
            let value = references.values[i].association
            // All cross-reference overlaps are examined, including unobserved retained roots.
            for j in references.values.indices where j < i {
                let other = references.values[j].association
                guard !overlap(value, other) || exactPair(value, other) else { throw EnvironmentError.duplicateAssociation }
            }
            if let bucket = buckets.firstIndex(where: { exactPair(value, references.values[$0[0]].association) }) {
                buckets[bucket].append(i)
            } else { buckets.append([i]) }
        }
        let activeProfiles = Set(references.state.profiles.profiles.map(\.id))
        var groups: [InstallationEnvironmentGroup] = [], entries: [DesktopInventoryEntry] = []
        for indices in buckets {
            let owners = indices.filter { references.values[$0].sources.contains(.current) }
            guard owners.count <= 1 else { throw EnvironmentError.duplicateAssociation }
            let owner = owners.first
            // Without an owner only a singleton may remain as unbound evidence.
            guard owner != nil || indices.count == 1 else { throw EnvironmentError.duplicateAssociation }
            // An owner selects the baseline; an unbound singleton has no selection ambiguity.
            let baseline = owner ?? indices[0]
            let instance = observations[baseline].instance
            if indices.count > 1 {
                guard let owner, references.values[owner].association.kind == .standardExternal,
                      references.values[owner].association.origin == .currentDefaults else {
                    throw EnvironmentError.duplicateAssociation
                }
                for index in indices {
                    let ref = references.values[index]
                    guard ref.association.kind == .standardExternal, ref.association.origin == .currentDefaults,
                          observations[index].instance == instance,
                          Self.sameProcessEvidence(observations[owner], observations[index]) else {
                        throw EnvironmentError.ambiguousInstance
                    }
                    if index != owner {
                        guard ref.sources == [.retained], !activeProfiles.contains(ref.association.profileID),
                              !references.state.associations.associations.contains(where: {
                                  $0.profileID == ref.association.profileID || $0.environmentID == ref.association.environmentID
                              }) else { throw EnvironmentError.invalidMetadata }
                    }
                }
            }
            if let instance {
                // Retained-only/prepared-only observed environments remain visible and block.
                guard let owner else { throw EnvironmentError.missingAssociation }
                guard mains.contains(instance.main) else { throw EnvironmentError.processChanged }
                entries.append(DesktopInventoryEntry(association: references.values[owner].association, instance: instance))
            }
            groups.append(InstallationEnvironmentGroup(referenceIndices: indices, ownerIndex: owner, instance: instance))
        }
        // Apply the unchanged uniqueness/member/unknown-instance checks to verified groups.
        try DesktopInstanceInventory(entries: entries, unknownCount: nativePIDs.count - entries.count).validate()
        self.references = references; self.observations = observations; self.groups = groups
        self.mains = mains; self.nativePIDs = nativePIDs; self.witnesses = witnesses; self.build = build
    }

    private static func sameProcessEvidence(_ a: InstallationReferenceObservation, _ b: InstallationReferenceObservation) -> Bool {
        // Association identity differs for aliases; all process evidence must still agree.
        InstallationReferenceObservation(association: a.association, instance: b.instance, before: b.before, after: b.after) == a
    }
}
