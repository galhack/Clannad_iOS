import Foundation
import SwiftUI

/// One run of the engine: the resolved game root and the title to show.
struct PlayerSession: Identifiable {
    let id = UUID()
    let gameRoot: URL
    let title: String
}

/// The launcher's state: where the game data is, whether it is complete, the
/// import in progress, and the running player session.
@MainActor
final class GameLibrary: ObservableObject {
    @Published var gameFolder: URL?
    @Published var isComplete = false
    @Published var missingFiles: [String] = []
    @Published var missingDirectories: [String] = []
    @Published var fileChecklist: [GameFile] = []
    @Published var directoryChecklist: [GameFile] = []
    @Published var archiveCount = 0
    @Published var gameFolderWritable = true
    @Published var errorMessage: String?
    @Published var importing = false
    @Published var importStatus = ""
    @Published var session: PlayerSession?
    /// The engine cannot be created twice in one process; after it exits the
    /// player has to relaunch the app.
    @Published var engineHasRun = false

    let transfer = TransferServer()

    /// The version shown on the launcher, from the bundle.
    var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var isPlaying: Bool { session != nil }

    init() {
        transfer.onFilesChanged = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        DebugScript.redirectLogIfRequested()
        refresh()
        // Debug/validation hook: start the receiver without a tap so the HTTP
        // contract can be exercised from a script (`CLANNAD_TRANSFER_CODE`
        // pins the pairing code in that case only).
        if ProcessInfo.processInfo.environment["CLANNAD_TRANSFER_AUTOSTART"] == "1" {
            let code = ProcessInfo.processInfo.environment["CLANNAD_TRANSFER_CODE"]
            transfer.start(forcedCode: code)
            NSLog("Clannad: transfer receiver started, code=%@", code ?? "(random)")
        }
        if DebugScript.autostartRequested {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
        }
    }

    /// Coming back to the front: files may have been copied in meanwhile.
    func refreshIfIdle() {
        if session == nil { refresh() }
    }

    /// Look for the game data again (after a copy, a network transfer, or the
    /// player pointing at another folder).
    func refresh() {
        let found = GamePaths.findGameFolder()
        gameFolder = found
        guard let folder = found else {
            isComplete = false
            missingFiles = GamePaths.sceneNames
            missingDirectories = GamePaths.dataDirectories
            fileChecklist = GamePaths.fileChecklist(in: GamePaths.defaultGameRoot)
            directoryChecklist = GamePaths.directoryChecklist(in: GamePaths.defaultGameRoot)
            archiveCount = 0
            gameFolderWritable = true
            return
        }
        gameFolderWritable = FileManager.default.isWritableFile(atPath: folder.path)
        isComplete = GamePaths.isCompleteGameFolder(folder)
        missingFiles = GamePaths.missingFiles(in: folder)
        missingDirectories = GamePaths.missingDirectories(in: folder)
        fileChecklist = GamePaths.fileChecklist(in: folder)
        directoryChecklist = GamePaths.directoryChecklist(in: folder)
        archiveCount = GamePaths.archiveCount(in: folder)
    }

    // MARK: - picking and importing

    /// A folder chosen in the Files app / folder picker.
    func pickGameFolder(_ url: URL) {
        #if targetEnvironment(macCatalyst)
        chooseGameFolderInPlace(url)
        #else
        importFolder(url)
        #endif
    }

    /// Play a folder where it is (Mac; the folder may be outside the sandbox).
    func chooseGameFolderInPlace(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        GamePaths.storeChosenGameFolder(url)
        refresh()
        if gameFolder == nil {
            errorMessage = "这个目录里没有找到游戏数据：需要 SceneZH.pck（或 Scene.pck）与 GameexeZH.dat（或 Gameexe.dat）。"
        } else if !isComplete {
            errorMessage = "游戏数据不完整（缺少：\(missingFiles.joined(separator: "、"))），请重新选择完整的游戏目录。"
        } else {
            errorMessage = nil
        }
    }

    /// Copy a picked folder into the app's own storage.  On a device this is
    /// the normal way to install the game data; on the Mac it is the fallback
    /// for a read-only folder.
    func importFolder(_ url: URL) {
        guard !importing else { return }
        importing = true
        importStatus = "正在复制「\(url.lastPathComponent)」…"
        errorMessage = nil
        let target = GamePaths.importTarget
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result {
                    try GameImport.install(from: url, into: target) { copied, total, name in
                        Task { @MainActor [weak self] in
                            self?.importStatus = "正在复制 \(copied)/\(total)：\(name)"
                        }
                    }
                }
            }.value
            guard let self else { return }
            self.importing = false
            self.importStatus = ""
            switch result {
            case .success:
                self.refresh()
                if self.gameFolder == nil {
                    self.errorMessage = "已复制，但里面没有找到游戏数据（SceneZH.pck / GameexeZH.dat）。请确认选择的是游戏目录本身。"
                } else if !self.isComplete {
                    self.errorMessage = "已复制，但游戏数据不完整（缺少：\(self.missingFiles.joined(separator: "、"))）。"
                }
            case .failure(let error):
                self.errorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - playing

    /// Prepare the save directory and start the engine on the found folder.
    func start() {
        guard !engineHasRun else {
            errorMessage = "本次运行中游戏引擎已经结束，无法在同一进程内再次启动。请退出并重新打开本应用。"
            return
        }
        guard let folder = gameFolder else {
            errorMessage = "还没有找到游戏数据。请用「导入游戏数据」放入你自己购买的游戏目录，或通过局域网接收。"
            return
        }
        guard isComplete else {
            errorMessage = "游戏数据不完整（缺少：\(missingFiles.joined(separator: "、"))），请重新导入完整的游戏目录。"
            return
        }
        guard !importing else { return }
        guard gameFolderWritable else {
            errorMessage = "游戏目录不可写（引擎需要写入存档与 key.toml）。请把游戏目录复制到 App 自己的存储后再开始，或换一个可写目录。"
            return
        }
        do {
            try GamePaths.prepareForPlay(folder)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        transfer.stop()
        engineHasRun = true
        session = PlayerSession(gameRoot: folder, title: "CLANNAD")
    }

    /// Back to the launcher when the player closes the game.
    func stopPlayback() {
        session = nil
        refresh()
    }

    /// The engine cannot run twice in one process; quitting is the only way to
    /// start over after the game ended.
    func quitApp() {
        exit(0)
    }
}
