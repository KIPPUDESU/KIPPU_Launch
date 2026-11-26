import Foundation

public struct InstanceScanOutcome: Sendable {
    public let records: [InstanceRecord]
    public let rejected: [VersionScanOutcome]
}

public struct InstanceScanner: Sendable {
    public let locator: VersionLocator
    public let metadata: InstanceMetadataReader

    public init(
        locator: VersionLocator = VersionLocator(),
        metadata: InstanceMetadataReader = InstanceMetadataReader()
    ) {
        self.locator = locator
        self.metadata = metadata
    }

    public func records(
        inRoot root: RegisteredRoot,
        fileManager: FileManager = .default
    ) -> InstanceScanOutcome {
        let directory = URL(fileURLWithPath: root.path)
        if !root.isLauncherOwned {
            return recordsForRegistration(at: directory, isLauncherOwned: false, fileManager: fileManager)
        }
        let outcome = locator.scan(root: directory, fileManager: fileManager)
        return InstanceScanOutcome(
            records: outcome.versions.map { record(from: $0, kind: .managed, fileManager: fileManager) },
            rejected: outcome.rejected
        )
    }

    /// 添加时也接受直接选中的版本目录
    public func recordsForRegistration(
        at url: URL,
        isLauncherOwned: Bool,
        fileManager: FileManager = .default
    ) -> InstanceScanOutcome {
        let outcome = locator.scanForRegistration(at: url, fileManager: fileManager)
        let kind: InstanceKind = isLauncherOwned ? .managed : .referenced
        return InstanceScanOutcome(
            records: outcome.versions.map { record(from: $0, kind: kind, fileManager: fileManager) },
            rejected: outcome.rejected
        )
    }

    public func record(
        from candidate: VersionCandidate,
        kind: InstanceKind,
        fileManager: FileManager = .default
    ) -> InstanceRecord {
        let enrichment = metadata.enrichment(for: candidate.directory, candidate: candidate, fileManager: fileManager)

        let managedVersion = kind == .managed
            ? try? String(contentsOf: candidate.directory.appending(path: ".kippu-data/minecraft-version"), encoding: .utf8)
            : nil
        return InstanceRecord(
            name: candidate.name,
            identityCanonical: candidate.identity.canonical,
            path: PathNormalization.normalized(candidate.directory),
            kind: kind,
            versionIdentifier: candidate.identifier,
            requiredJavaMajorVersion: candidate.javaMajorVersion,
            requiredJavaComponent: candidate.javaComponent,
            minecraftVersion: enrichment.minecraftVersion ?? managedVersion,
            loader: enrichment.loader,
            loaderVersion: enrichment.loaderVersion,
            packName: enrichment.packName,
            packVersionId: enrichment.packVersionId,
            memoryMB: enrichment.memoryMB,
            javaPath: enrichment.javaPath
        )
    }
}

public struct DiscoveredRoot: Sendable, Hashable {
    public let path: String
    public let instanceCount: Int
    public let suggestion: String

    public init(path: String, instanceCount: Int, suggestion: String) {
        self.path = path
        self.instanceCount = instanceCount
        self.suggestion = suggestion
    }
}
