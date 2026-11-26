import Foundation
import ImageIO
import KIPPULaunchCore
import Observation

enum BackgroundScope: Hashable {
    case instance(UUID), instances, application

    fileprivate var key: String {
        switch self {
        case let .instance(id): id.uuidString
        case .instances: "instances"
        case .application: "application"
        }
    }
}

struct BackgroundStyle: Codable, Equatable {
    let imageID: UUID
    var transparency = 50.0
    var blur = 0.0
}

/// 表单持有临时副本直到提交或关闭
final class BackgroundImport: Sendable {
    let id = UUID()
    let url: URL

    private init() {
        url = FileManager.default.temporaryDirectory.appending(component: "kippu-background-" + id.uuidString)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @concurrent static func prepare(_ source: URL) async throws -> BackgroundImport {
        let hasScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { source.stopAccessingSecurityScopedResource() } }
        let resolved = source.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let importedImage = BackgroundImport()
        try FileManager.default.copyItem(at: resolved, to: importedImage.url)
        try Task.checkCancellation()
        guard thumbnail(at: importedImage.url, pixels: 128) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return importedImage
    }

    static func thumbnail(at url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @concurrent static func load(at url: URL, pixels: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return thumbnail(at: url, pixels: pixels)
    }
}

@MainActor @Observable final class LauncherBackgrounds {
    private let directory: URL?
    private let defaults: UserDefaults
    private let settingsKey = "launcherBackgrounds"
    private var styles: [String: BackgroundStyle]

    init(directory: URL? = try? AppPaths.standard().backgrounds, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        styles = defaults.data(forKey: settingsKey).flatMap {
            try? JSONDecoder().decode([String: BackgroundStyle].self, from: $0)
        } ?? [:]
    }

    func style(for scope: BackgroundScope) -> BackgroundStyle? { styles[scope.key] }

    func inherited(by scope: BackgroundScope) -> BackgroundStyle? {
        switch scope {
        case .instance: style(for: .instances) ?? style(for: .application)
        case .instances: style(for: .application)
        case .application: nil
        }
    }

    func instanceBackground(for id: UUID) -> BackgroundStyle? {
        style(for: .instance(id)) ?? style(for: .instances)
    }

    func url(for style: BackgroundStyle) -> URL? {
        directory?.appending(component: style.imageID.uuidString)
    }

    func removeOverrides(for instanceIDs: Set<UUID>) {
        let keys = Set(instanceIDs.map(\.uuidString))
        let remaining = styles.filter { !keys.contains($0.key) }
        guard remaining.count != styles.count, let data = try? JSONEncoder().encode(remaining) else { return }
        save(remaining, data: data)
    }

    func apply(_ style: BackgroundStyle?, to scope: BackgroundScope, imported: BackgroundImport?) throws {
        var updated = styles
        updated[scope.key] = style
        let data = try JSONEncoder().encode(updated)
        if let style {
            guard let directory, let file = url(for: style) else { throw CocoaError(.fileNoSuchFile) }
            if !FileManager.default.fileExists(atPath: file.path) {
                guard let imported, imported.id == style.imageID else { throw CocoaError(.fileReadNoSuchFile) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: imported.url, to: file)
            }
        }
        save(updated, data: data)
    }

    private func save(_ updated: [String: BackgroundStyle], data: Data) {
        let removed = Set(styles.values.map(\.imageID)).subtracting(updated.values.map(\.imageID))
        defaults.set(data, forKey: settingsKey)
        styles = updated
        if let directory {
            for id in removed { try? FileManager.default.removeItem(at: directory.appending(component: id.uuidString)) }
        }
    }
}
