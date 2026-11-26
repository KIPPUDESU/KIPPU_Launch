import Foundation

public struct InstanceMetadataReader: Sendable {
    public init() {}

    public func enrichment(
        for folder: URL,
        candidate: VersionCandidate,
        fileManager: FileManager = .default
    ) -> InstanceEnrichment {
        var enrichment = InstanceEnrichment()

        // 能从整合包清单读到的版本优先于库坐标
        if let manifest = readModpackManifest(in: folder, fileManager: fileManager) {
            enrichment.packName = manifest.name
            enrichment.packVersionId = manifest.versionId
            if let minecraft = manifest.dependencies["minecraft"], !minecraft.isEmpty {
                enrichment.minecraftVersion = minecraft
            }
            applyLoaderDependencies(manifest.dependencies, to: &enrichment)
        }

        let libraries = readLibraryNames(from: candidate.jsonFile, fileManager: fileManager)
        applyLibraryInference(libraries, to: &enrichment, mainClass: candidate.mainClass)

        applyLegacyLauncherSettings(in: folder, to: &enrichment, fileManager: fileManager)

        return enrichment
    }

    private struct ModpackManifest {
        var name: String?
        var versionId: String?
        var dependencies: [String: String] = [:]
    }

    private func readModpackManifest(in folder: URL, fileManager: FileManager) -> ModpackManifest? {
        for fileName in ["modrinth.index.json", "modpack.cfg"] {
            let url = folder.appending(path: fileName)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let root = try? JSONSerialization.jsonObject(with: data),
                  var object = root as? [String: Any]
            else { continue }

            if let nested = object["manifest"] as? [String: Any] {
                object = nested
            }

            var manifest = ModpackManifest()
            manifest.name = object["name"] as? String
            manifest.versionId = object["versionId"] as? String

            if let dependencies = object["dependencies"] as? [String: Any] {
                for (key, value) in dependencies {
                    if let text = value as? String { manifest.dependencies[key.lowercased()] = text }
                }
            }
            return manifest
        }
        return nil
    }

    /// Forge 的整合包清单会省略版本号里的 Minecraft 前缀
    private func applyLoaderDependencies(_ dependencies: [String: String], to enrichment: inout InstanceEnrichment) {
        let mapping: [(key: String, loader: LoaderKind)] = [
            ("neoforge", .neoforge),
            ("forge", .forge),
            ("quilt-loader", .quilt),
            ("fabric-loader", .fabric),
        ]
        for (key, loader) in mapping {
            if let version = dependencies[key], !version.isEmpty {
                enrichment.loader = loader
                enrichment.loaderVersion = version
                return
            }
        }
        if dependencies["minecraft"] != nil {
            enrichment.loader = .vanilla
        }
    }

    private func readLibraryNames(from jsonFile: URL, fileManager: FileManager) -> [String] {
        guard let data = try? Data(contentsOf: jsonFile, options: .mappedIfSafe),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let libraries = object["libraries"] as? [[String: Any]]
        else { return [] }

        return libraries.compactMap { $0["name"] as? String }
    }

    private func applyLibraryInference(
        _ libraries: [String],
        to enrichment: inout InstanceEnrichment,
        mainClass: String?
    ) {
        for name in libraries {
            let parts = name.split(separator: ":").map(String.init)
            guard parts.count >= 3 else { continue }
            let groupArtifact = "\(parts[0]):\(parts[1])"
            let version = parts[2]

            switch groupArtifact {
            case "net.minecraftforge:fmlloader", "net.minecraftforge:forge":
                let segments = version.split(separator: "-", maxSplits: 1).map(String.init)
                guard segments.count == 2 else { continue }
                if enrichment.minecraftVersion == nil { enrichment.minecraftVersion = segments[0] }
                if enrichment.loader == .unknown {
                    enrichment.loader = .forge
                    enrichment.loaderVersion = segments[1]
                }
            case "net.neoforged:neoforge", "net.neoforged.fancymodloader:loader":
                if enrichment.loader == .unknown {
                    enrichment.loader = .neoforge
                    enrichment.loaderVersion = version
                }
            case "net.fabricmc:fabric-loader":
                if enrichment.loader == .unknown {
                    enrichment.loader = .fabric
                    enrichment.loaderVersion = version
                }
            case "org.quiltmc:quilt-loader":
                if enrichment.loader == .unknown {
                    enrichment.loader = .quilt
                    enrichment.loaderVersion = version
                }
            default:
                continue
            }
        }

        guard enrichment.loader == .unknown else { return }
        guard let mainClass else {
            enrichment.loader = .vanilla
            return
        }
        if mainClass.contains("bootstraplauncher") || mainClass.contains("forge") {
            enrichment.loader = .forge
        } else if mainClass.contains("quiltmc") {
            enrichment.loader = .quilt
        } else if mainClass.contains("fabricmc") {
            enrichment.loader = .fabric
        } else {
            enrichment.loader = .vanilla
        }
    }

    private func applyLegacyLauncherSettings(
        in folder: URL,
        to enrichment: inout InstanceEnrichment,
        fileManager: FileManager
    ) {
        let url = folder.appending(path: "hmclversion.cfg")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let maxMemory = object["maxMemory"] as? Int, maxMemory > 0 {
            enrichment.memoryMB = maxMemory
        }
        if let javaDir = object["javaDir"] as? String, !javaDir.isEmpty {
            enrichment.javaPath = javaDir
        }
    }
}
