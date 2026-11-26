import Foundation

enum VersionInheritance {
    static func resolve(_ child: VersionJSON, in directory: URL, shared: URL) throws -> (VersionJSON, URL) {
        let roots = [directory.deletingLastPathComponent(), shared.appending(path: "versions")]
        var visited: Set<String> = []
        func read(_ version: VersionJSON, directory: URL) throws -> (VersionJSON, URL) {
            guard visited.count < 32, visited.insert(version.id).inserted else {
                throw InstancePlanningError.malformedVersionFile(reason: "父版本循环或层数过多")
            }
            let jarID = version.jar ?? version.id
            guard safeComponent(jarID) else { throw InstancePlanningError.malformedVersionFile(reason: "客户端文件名无效") }
            var jar = directory.appending(path: jarID + ".jar")
            var result = version
            if let parentID = version.inheritsFrom {
                guard safeComponent(parentID) else { throw InstancePlanningError.malformedVersionFile(reason: "父版本名称无效") }
                let candidate = roots.lazy.compactMap { VersionLocator().locate(in: $0.appending(path: parentID)).version }.first { $0.identifier == parentID }
                guard let candidate else { throw InstancePlanningError.parentMissing(parentID) }
                let parent = try JSONDecoder().decode(VersionJSON.self, from: Data(contentsOf: candidate.jsonFile))
                let (base, parentJar) = try read(parent, directory: candidate.directory)
                result = merge(base, version)
                if version.jar == nil || version.jar == base.id { jar = parentJar }
            }
            if let explicit = version.jar, !FileManager.default.fileExists(atPath: jar.path) {
                jar = roots.map { $0.appending(path: explicit).appending(path: explicit + ".jar") }
                    .first { FileManager.default.fileExists(atPath: $0.path) } ?? jar
            }
            return (result, jar)
        }
        return try read(child, directory: directory)
    }

    static func merge(_ base: VersionJSON, _ patch: VersionJSON) -> VersionJSON {
        var merged = base
        merged.id = patch.id
        merged.inheritsFrom = nil
        merged.mainClass = patch.mainClass ?? base.mainClass
        merged.jar = patch.jar ?? base.jar
        merged.type = patch.type ?? base.type
        merged.assets = patch.assets ?? base.assets
        merged.assetIndex = patch.assetIndex ?? base.assetIndex
        merged.downloads = patch.downloads ?? base.downloads
        merged.javaVersion = patch.javaVersion ?? base.javaVersion
        merged.logging = patch.logging ?? base.logging
        if let args = patch.arguments {
            var combined = base.arguments ?? Arguments()
            if let game = args.game { combined.game = (combined.game ?? []) + game }
            if let jvm = args.jvm { combined.jvm = (combined.jvm ?? []) + jvm }
            merged.arguments = combined
        }
        if let legacy = patch.minecraftArguments {
            merged.minecraftArguments = legacy
            if patch.arguments?.game == nil { merged.arguments?.game = nil }
        }
        func libraryKey(_ library: Library) -> String {
            var parts = library.name.components(separatedBy: ":")
            if parts.count >= 3 { parts.remove(at: 2) }
            return parts.joined(separator: ":")
        }
        let overrides = patch.libraries ?? []
        let overriddenKeys = Set(overrides.map(libraryKey))
        merged.libraries = overrides + (base.libraries ?? []).filter { !overriddenKeys.contains(libraryKey($0)) }
        return merged
    }
}

func safeComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/")
        && !value.contains("\\") && !value.contains(":") && value.rangeOfCharacter(from: .controlCharacters) == nil
}
