import Foundation

/// Where the port finds the player's game data and keeps its own files.
///
/// * iPhone, iPad, Vision Pro: the game folder is copied into the app's
///   Documents as `Documents/Clannad` (visible in the Files app and over
///   Finder file sharing), or received there over the local network.
/// * Mac Catalyst: the player may point at the game folder where it is
///   installed, or import a copy into the app's own storage.
///
/// A complete CLANNAD data folder holds `SceneZH.pck` (or `Scene.pck`) and
/// `GameexeZH.dat` (or `Gameexe.dat`), plus the `dat`, `g00`, `bgm`, `koe`,
/// `wav`, `mov`, `gan` directories.  The engine writes its saves into
/// `<gameRoot>/savedata`; we create that directory on first run and seed it
/// from the player's own `savedata_zh`/`SAVEDATA` folder, never from
/// anything bundled in the app.
enum GamePaths {
    static let fileManager = FileManager.default
    static let appName = "Clannad"
    static let gameFolderName = "Clannad"

    /// The scene archive names, in the order this port looks for them.  The
    /// Simplified-Chinese Steam release ships `SceneZH.pck`; the original
    /// release ships `Scene.pck`.  The vendored engine resolves the localized
    /// name from the Gameexe it opens, so no alias file is required.
    static let sceneNames = ["SceneZH.pck", "Scene.pck"]
    /// The Gameexe names, in the order this port looks for them.  The engine
    /// already accepts the localized names itself.
    static let gameexeNames = ["GameexeZH.dat", "Gameexe.dat"]
    /// The directories a complete game folder has (checked for the launcher's
    /// completeness report; a missing one is a warning, not a hard error).
    static let dataDirectories = ["dat", "g00", "bgm", "koe", "wav", "mov", "gan"]
    /// Save-seed directories shipped inside the game folder by the Chinese
    /// patch / the original release.
    static let seedDirectoryNames = ["savedata_zh", "SAVEDATA"]
    /// The engine's save directory, relative to the game root.
    static let saveDirectoryName = "savedata"

    // MARK: - app folders

    static var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var applicationSupport: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var caches: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Where the game data is expected by default: `Documents/Clannad` on a
    /// device (visible over file sharing), the app's Application Support on
    /// the Mac (the Mac's Documents belong to the user; an in-place folder can
    /// be chosen separately).
    static var defaultGameRoot: URL {
        #if targetEnvironment(macCatalyst)
        let url = applicationSupport.appendingPathComponent("\(appName)/Game", isDirectory: true)
        #else
        let url = documents.appendingPathComponent(gameFolderName, isDirectory: true)
        #endif
        return url
    }

    /// The folder network transfers are written to.  It is the game root
    /// itself, so a successful transfer is immediately playable.
    static var transferTarget: URL { defaultGameRoot }

    /// Where `导入游戏数据` copies a picked folder to.
    static var importTarget: URL { defaultGameRoot }

    /// True when the platform prefers playing a folder where it is (Mac).
    static var prefersInPlaceGameFolder: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    // MARK: - the folder the player chose (Mac, or an in-place import)

    private static let chosenPathKey = "gameFolderPath"
    private static let bookmarkKey = "gameFolderBookmark"
    /// The resolved folder and its held security-scoped access (one per run).
    private static var resolvedChosenFolder: URL?

    static var chosenGameFolder: URL? {
        if let resolved = resolvedChosenFolder { return resolved }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                #if targetEnvironment(macCatalyst)
                _ = url.startAccessingSecurityScopedResource()
                #endif
                if stale { storeChosenGameFolder(url) }
                resolvedChosenFolder = url
                return url
            }
        }
        if let path = defaults.string(forKey: chosenPathKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            resolvedChosenFolder = url
            return url
        }
        return nil
    }

    static func storeChosenGameFolder(_ url: URL) {
        resolvedChosenFolder = url
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: chosenPathKey)
        #if targetEnvironment(macCatalyst)
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
        } else {
            defaults.removeObject(forKey: bookmarkKey)
        }
        #else
        defaults.removeObject(forKey: bookmarkKey)
        #endif
    }

    static func clearChosenGameFolder() {
        resolvedChosenFolder = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: chosenPathKey)
        defaults.removeObject(forKey: bookmarkKey)
    }

    // MARK: - finding the game

    /// Debug/validation override: an environment variable (simctl, devicectl,
    /// terminal) or, on the Mac where LaunchServices owns the environment, the
    /// `CLANNAD_GAME_DIR` user default.
    static var debugGameDirectoryOverride: String? {
        if let value = ProcessInfo.processInfo.environment["CLANNAD_GAME_DIR"], !value.isEmpty {
            return value
        }
        if let value = UserDefaults.standard.string(forKey: "CLANNAD_GAME_DIR"), !value.isEmpty {
            return value
        }
        return nil
    }

    /// The game folder: one the player picked, a debug override, or the
    /// default `Documents/Clannad` location (or a folder below it).
    static func findGameFolder() -> URL? {
        if let override = debugGameDirectoryOverride {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if looksLikeGameFolder(url) { return url }
        }
        if let chosen = chosenGameFolder {
            if looksLikeGameFolder(chosen) { return chosen }
            // The player picked a folder that contains the data folder.
            if let found = search(chosen, depth: 2, where: looksLikeGameFolder) { return found }
        }
        let root = defaultGameRoot
        if looksLikeGameFolder(root) { return root }
        // Tolerate a nested layout (e.g. Documents/Clannad/data, or
        // Documents/CLANNAD_Portable/...).
        if let found = search(root, depth: 2, where: looksLikeGameFolder) { return found }
        #if !targetEnvironment(macCatalyst)
        if let found = search(documents, depth: 2, where: looksLikeGameFolder) { return found }
        #endif
        return nil
    }

    /// A folder worth showing as a game folder: it has a scene archive, or at
    /// least the Gameexe plus a `g00` directory, so the launcher can report
    /// what is still missing instead of pretending there is no data at all.
    static func looksLikeGameFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        if file(named: sceneNames[0], in: url) != nil || file(named: sceneNames[1], in: url) != nil {
            return true
        }
        let hasGameexe = gameexeNames.contains { file(named: $0, in: url) != nil }
        let hasG00 = isDirectory(url.appendingPathComponent("g00"), orCaseInsensitive: true)
        return hasGameexe && hasG00
    }

    /// True when the folder has both the scene archive and the Gameexe, i.e.
    /// the engine has a chance to start.
    static func isCompleteGameFolder(_ folder: URL) -> Bool {
        hasSceneArchive(folder) && hasGameexe(folder)
    }

    static func hasSceneArchive(_ folder: URL) -> Bool {
        sceneNames.contains { file(named: $0, in: folder) != nil }
    }

    static func hasGameexe(_ folder: URL) -> Bool {
        gameexeNames.contains { file(named: $0, in: folder) != nil }
    }

    /// The files the launcher lists, present or not, in the order shown.  The
    /// localized name wins when it exists, so the checklist reads correctly
    /// for both the Chinese Steam release and the original data.
    static func fileChecklist(in folder: URL) -> [GameFile] {
        let scene = sceneNames.first { file(named: $0, in: folder) != nil } ?? sceneNames[0]
        let gameexe = gameexeNames.first { file(named: $0, in: folder) != nil } ?? gameexeNames[0]
        return [
            GameFile(name: scene, present: file(named: scene, in: folder) != nil),
            GameFile(name: gameexe, present: file(named: gameexe, in: folder) != nil),
        ]
    }

    /// The directories of the data folder, present or not.
    static func directoryChecklist(in folder: URL) -> [GameFile] {
        dataDirectories.map { name in
            GameFile(name: name + "/", present: isDirectory(folder.appendingPathComponent(name),
                                                           orCaseInsensitive: true))
        }
    }

    static func missingFiles(in folder: URL) -> [String] {
        var missing: [String] = []
        if !hasSceneArchive(folder) { missing.append(sceneNames[0]) }
        if !hasGameexe(folder) { missing.append(gameexeNames[0]) }
        return missing
    }

    static func missingDirectories(in folder: URL) -> [String] {
        directoryChecklist(in: folder).filter { !$0.present }.map { $0.name }
    }

    /// Number of `.pck`/`.dat` archives in the folder (informational).
    static func archiveCount(in folder: URL) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter {
            let ext = ($0 as NSString).pathExtension.lowercased()
            return ext == "pck" || ext == "dat"
        }.count
    }

    // MARK: - first-run preparation (saves, engine aliases)

    /// Makes the game root ready for the engine and returns the save folder.
    ///
    /// Creates `<root>/savedata` when absent and seeds it from the player's
    /// own `savedata_zh`/`SAVEDATA` folder (config, read marks and slots),
    /// once.
    ///
    /// Writes only inside the game root; throws a descriptive error when the
    /// folder is read-only (an in-place Mac folder cannot be used that way).
    @discardableResult
    static func prepareForPlay(_ folder: URL) throws -> URL {
        guard isCompleteGameFolder(folder) else {
            throw PrepareError.incomplete(missing: missingFiles(in: folder))
        }
        // The engine writes `key.toml` (the recovered resource key) and
        // `savedata/` into the game root, so it has to be writable end to end.
        guard fileManager.isWritableFile(atPath: folder.path) else {
            throw PrepareError.notWritable(folder.path)
        }

        let saveDir = folder.appendingPathComponent(saveDirectoryName, isDirectory: true)
        let hadSaveDir = isDirectory(saveDir, orCaseInsensitive: false)
        if !hadSaveDir {
            do {
                try fileManager.createDirectory(at: saveDir, withIntermediateDirectories: true)
            } catch {
                throw PrepareError.notWritable(error.localizedDescription)
            }
            seedSaves(into: saveDir, from: folder)
        }
        if !fileManager.isWritableFile(atPath: saveDir.path) {
            throw PrepareError.notWritable("\(saveDir.path) 不可写")
        }

        // The engine resolves the localized archive names itself
        // (GameexeZH.dat -> SceneZH.pck), so no alias file is needed here.
        return saveDir
    }

    /// True for the numbered save slots (`0000.sav`, `0002.bmp`, ...).
    private static func isSlotSave(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".sav") || lower.hasSuffix(".bmp") else { return false }
        let stem = lower.dropLast(4)
        return stem.count == 4 && stem.allSatisfy { $0.isNumber }
    }

    /// Copies the top-level files of the game's own seed folder into the save
    /// folder.  Existing files are never overwritten.
    private static func seedSaves(into saveDir: URL, from folder: URL) {
        for seedName in seedDirectoryNames {
            guard let seed = directory(named: seedName, in: folder) else { continue }
            let entries = (try? fileManager.contentsOfDirectory(
                at: seed, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            var copied = 0
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard !isDir else { continue }
                // Slot saves written by the Windows game are copied only when
                // asked for: the save reader is still being taught to accept
                // them, and a file it cannot parse used to stop the VM.
                // config.sav / global.sav / read.sav (settings and read marks)
                // are safe and are copied unconditionally.
                if isSlotSave(entry.lastPathComponent),
                   ProcessInfo.processInfo.environment["CLANNAD_SEED_SLOTS"] != "1" {
                    continue
                }
                let target = saveDir.appendingPathComponent(entry.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                do {
                    try fileManager.copyItem(at: entry, to: target)
                    copied += 1
                } catch {
                    NSLog("Clannad: seeding save %@ failed: %@", entry.lastPathComponent, error.localizedDescription)
                }
            }
            if copied > 0 {
                NSLog("Clannad: seeded %d save file(s) from %@", copied, seedName)
                return
            }
        }
    }

    // MARK: - helpers

    /// The file of that name in the folder, case aside (the game was made for
    /// case-insensitive file systems).
    static func file(named name: String, in folder: URL) -> URL? {
        let direct = folder.appendingPathComponent(name)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        let entries = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        if let match = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return folder.appendingPathComponent(match)
        }
        return nil
    }

    static func directory(named name: String, in folder: URL) -> URL? {
        let direct = folder.appendingPathComponent(name)
        if isDirectory(direct, orCaseInsensitive: false) { return direct }
        let entries = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        if let match = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            let url = folder.appendingPathComponent(match)
            if isDirectory(url, orCaseInsensitive: false) { return url }
        }
        return nil
    }

    static func isDirectory(_ url: URL, orCaseInsensitive: Bool) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    private static func search(_ dir: URL, depth: Int, where match: (URL) -> Bool) -> URL? {
        let children = (try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let sorted = children.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for child in sorted {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if match(child) { return child }
            if depth > 1, let found = search(child, depth: depth - 1, where: match) { return found }
        }
        return nil
    }

    // MARK: - errors

    enum PrepareError: LocalizedError {
        case incomplete(missing: [String])
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .incomplete(let missing):
                return "游戏数据不完整（缺少：\(missing.joined(separator: "、"))），请重新导入完整的游戏目录。"
            case .notWritable(let detail):
                return "游戏目录不可写，无法创建存档（\(detail)）。请把游戏目录复制到 App 自己的存储后再开始游戏。"
            }
        }
    }
}

/// One file or directory the launcher reports on.
struct GameFile: Identifiable {
    let name: String
    let present: Bool
    var id: String { name }
}
