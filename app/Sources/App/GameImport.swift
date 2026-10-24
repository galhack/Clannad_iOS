import Foundation

/// Copies a game folder picked in the Files app (or a Mac folder the player
/// wants inside the app) into the app's own game root.
///
/// Only the top-level entries of the data folder are moved into place, each
/// through a hidden staging name and an atomic rename, so a cancelled or
/// failed import never leaves a half-copied archive behind.  An existing
/// `savedata` directory is always kept: importing new game data must not wipe
/// the player's saves.
enum GameImport {
    enum ImportError: LocalizedError {
        case notAFolder
        case noGameData
        case alreadyExists

        var errorDescription: String? {
            switch self {
            case .notAFolder:
                return "请选择整个游戏目录（里面包含 SceneZH.pck、GameexeZH.dat 与 g00 等文件夹），而不是单个文件。"
            case .noGameData:
                return "这个目录里没有找到游戏数据（需要 SceneZH.pck 或 Scene.pck，以及 GameexeZH.dat 或 Gameexe.dat）。"
            case .alreadyExists:
                return "目标位置已有同名项目，且无法替换。"
            }
        }
    }

    /// Install `source` into `target`.  `source` may be the data folder itself
    /// or a folder that contains a `data` subfolder.
    ///
    /// - Parameter progress: called off the main thread with
    ///   (finished item count, total item count, current name).
    static func install(from source: URL, into target: URL,
                        progress: ((Int, Int, String) -> Void)? = nil) throws {
        let fm = FileManager.default
        let dataFolder = try resolveDataFolder(source)
        let sourceURL = dataFolder.resolvingSymlinksInPath().standardizedFileURL
        let targetURL = target.resolvingSymlinksInPath().standardizedFileURL
        if sourceURL == targetURL {
            return
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            return try installEntries(from: sourceURL, into: targetURL, progress: progress)
        }
        return try installEntries(from: sourceURL, into: targetURL, progress: progress)
    }

    /// The folder that actually holds the game files.
    private static func resolveDataFolder(_ source: URL) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.notAFolder
        }
        if GamePaths.looksLikeGameFolder(source) { return source }
        let nested = source.appendingPathComponent("data", isDirectory: true)
        if GamePaths.looksLikeGameFolder(nested) { return nested }
        throw ImportError.noGameData
    }

    private static func installEntries(from source: URL, into target: URL,
                                       progress: ((Int, Int, String) -> Void)?) throws {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: source.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        guard !names.isEmpty else { throw ImportError.noGameData }

        for (index, name) in names.enumerated() {
            progress?(index, names.count, name)
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            // Never overwrite the player's saves with the seed folder.
            if name == GamePaths.saveDirectoryName, fm.fileExists(atPath: to.path) {
                NSLog("Clannad: import keeps existing %@", to.path)
                continue
            }
            let staging = target.appendingPathComponent(".import-\(UUID().uuidString)")
            do {
                try? fm.removeItem(at: staging)
                try fm.copyItem(at: from, to: staging)
                if fm.fileExists(atPath: to.path) {
                    try fm.removeItem(at: to)
                }
                try fm.moveItem(at: staging, to: to)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
        progress?(names.count, names.count, "")
    }
}
