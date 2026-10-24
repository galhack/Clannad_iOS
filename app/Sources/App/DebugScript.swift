import Foundation

/// Small developer hooks used for unattended device verification.  They are
/// inert in normal use: an environment variable has to be set by a debugger,
/// `simctl launch` or the validation scripts.
enum DebugScript {
    static let controlEnabled = ProcessInfo.processInfo.environment["CLANNAD_DEBUG_CONTROL"] == "1"

    struct Command: Decodable {
        let action: String
        let x: Double?
        let y: Double?
        let key: Int32?
        let delta: Int32?
    }

    /// A one-shot device replay command, enabled only by the launch environment.
    /// Copy JSON to Documents/clannad-command.json with devicectl; consuming it
    /// removes the file so a slow frame can never repeat a save/menu action.
    static func consumeCommand() -> Command? {
        guard controlEnabled,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = documents.appendingPathComponent("clannad-command.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: url))
            try FileManager.default.removeItem(at: url)
            return command
        } catch {
            NSLog("Clannad: debug command failed: %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// `CLANNAD_AUTOSTART=1` starts the game as soon as the launcher finds the
    /// data, which makes smoke tests on a device one command.
    static var autostartRequested: Bool {
        let value = ProcessInfo.processInfo.environment["CLANNAD_AUTOSTART"]
            ?? UserDefaults.standard.string(forKey: "CLANNAD_AUTOSTART")
            ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    /// `CLANNAD_LOG` (a file path) redirects stdout/stderr to that file, so a
    /// device run leaves the engine's diagnostics behind for inspection.
    static func redirectLogIfRequested() {
        var path = ProcessInfo.processInfo.environment["CLANNAD_LOG"]
            ?? UserDefaults.standard.string(forKey: "CLANNAD_LOG")
        // Always keep a log on device: crashes on a physical device leave no
        // console, so the engine's stderr (panic messages, [SIGLUS_IOS_ERROR])
        // and our own NSLog lines go to Documents/clannad.log and can be pulled
        // with `devicectl device copy from`.
        if path == nil || path!.isEmpty {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            let candidate = ProcessInfo.processInfo.environment["CLANNAD_LOG_NAME"] ?? "clannad.log"
            let name = candidate.hasSuffix(".log") && (candidate as NSString).lastPathComponent == candidate
                ? candidate : "clannad.log"
            path = documents?.appendingPathComponent(name).path
        }
        guard let path, !path.isEmpty else { return }
        _ = freopen(path, "a", stdout)
        _ = freopen(path, "a", stderr)
    }
}
