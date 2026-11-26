import Foundation
import KIPPULaunchCore

/// 实例已写入磁盘时重试只补登记
@MainActor final class GameInstallation {
    let runtimes: [JavaRuntime]
    let register: (URL) throws -> Void
    private var installed: URL?

    init(runtimes: [JavaRuntime], register: @escaping (URL) throws -> Void) {
        self.runtimes = runtimes
        self.register = register
    }

    func run(version: String, name: String, job: DownloadJob, pack: () async throws -> URL?,
             removeDownloadedPack: Bool = false) async throws -> String {
        if installed == nil {
            let file = try await pack()
            defer {
                if removeDownloadedPack, let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            }
            try Task.checkCancellation()
            let installer = try GameInstaller(paths: AppPaths.standard())
            installed = try await installer.install(version: version, name: name, packURL: file, java: runtimes) { stage, done, total in
                await job.report(stage, done: done, total: total)
            }
        }
        if let installed {
            do {
                try register(installed)
            } catch {
                throw InstallError.message("游戏文件已安装到「\(installed.path)」，保存实例清单失败。\n\(error.localizedDescription)")
            }
        }
        return "已添加到实例列表"
    }
}
