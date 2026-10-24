import Foundation
import Network

/// Receives the game files from a Mac over the local network
/// (`tools/push_data.py`): a minimal HTTP server, one request per connection.
///
/// Contract (protocol 1, agreed with the Mac-side client):
///
///   GET  /info                                  server identity, no code
///   GET  /status?code=<code>                    files already received
///   POST /upload?path=<rel>&size=<n>&code=<c>   a file of the game folder
///
/// The pairing code is shown by the launcher.  It can be passed as the `code`
/// query parameter or as the `X-Clannad-Code` header.  Upload paths are
/// POSIX-relative under the game root, so the nested `g00/`, `bgm/`, `koe/`
/// and `mov/` trees can be sent.  A body is written to `<name>.part` next to
/// its final place and renamed when complete, so an interrupted transfer
/// never leaves a truncated archive behind; sending a file again replaces it.
final class TransferServer: ObservableObject {
    static let port: UInt16 = 8765
    static let protocolVersion = 1

    @Published private(set) var running = false
    @Published private(set) var lastEvent = ""
    @Published private(set) var bytesReceived: Int64 = 0
    /// The pairing code of this session, shown by the launcher.
    @Published private(set) var code = ""

    var onFilesChanged: (() -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "clannad.transfer")
    /// The code and the guessing guard, shared by the main thread and `queue`
    /// under `lock`.
    private let lock = NSLock()
    private var activeCode = ""
    private var failures: [Date] = []
    private var lockedUntil = Date.distantPast
    private var lockouts = 0
    private static let maxFailures = 5

    // MARK: - lifecycle

    /// Five wrong codes lock the receiver (1 minute, doubling with every
    /// further lockout) and replace the code with a new random one, so what a
    /// guesser learned is worthless and at most five guesses ever meet the
    /// same code; the player reads the new code on the screen.
    private func authorize(_ candidates: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now < lockedUntil || activeCode.isEmpty { return false }
        if candidates.contains(where: { !$0.isEmpty && $0 == activeCode }) { return true }
        failures.append(now)
        if failures.count >= Self.maxFailures {
            let minutes = 1 << min(lockouts, 6)
            lockouts += 1
            lockedUntil = now.addingTimeInterval(Double(minutes) * 60)
            failures.removeAll()
            let fresh = Self.newCode()
            activeCode = fresh
            DispatchQueue.main.async {
                self.code = fresh
                self.lastEvent = "配对码错误次数过多：已更换配对码，暂停接收 \(minutes) 分钟。"
            }
        }
        return false
    }

    private static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    func start(forcedCode: String? = nil) {
        guard listener == nil else { return }
        let fresh = forcedCode ?? Self.newCode()
        code = fresh
        lock.lock()
        activeCode = fresh
        failures.removeAll()
        lockedUntil = .distantPast
        lockouts = 0
        lock.unlock()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "Clannad", type: "_clannad._tcp")
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.running = true
                    case .failed(let error):
                        self?.running = false
                        self?.lastEvent = "监听失败：\(error)"
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastEvent = "无法开启传输服务：\(error)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        code = ""
        lock.lock()
        activeCode = ""
        lock.unlock()
    }

    /// The device's IPv4 addresses on Wi-Fi / Ethernet, for the launcher.
    static func addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    // MARK: - connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHeader(conn, buffer: Data())
    }

    private func readHeader(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let rest = buffer[range.upperBound...]
                self.handle(conn, head: head, initialBody: Data(rest))
            } else if error != nil || complete || buffer.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.readHeader(conn, buffer: buffer)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        var query: [String: String]
        var headers: [String: String]

        var codeCandidates: [String] {
            var values: [String] = []
            if let value = query["code"] { values.append(value) }
            if let value = headers["x-clannad-code"] { values.append(value) }
            return values
        }
    }

    private func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            let rawQuery = String(target[target.index(after: mark)...])
            for pair in rawQuery.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = kv.first.map({ String($0).removingPercentEncoding ?? String($0) }) else { continue }
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: method, path: path, query: query, headers: headers)
    }

    private func handle(_ conn: NWConnection, head: String, initialBody: Data) {
        guard let request = parse(head) else {
            return respond(conn, 400, json: ["ok": false, "error": "bad request"])
        }
        switch (request.method, request.path) {
        case ("GET", "/info"):
            return respond(conn, 200, json: infoJSON())
        case ("GET", "/status"):
            guard authorize(request.codeCandidates) else {
                return respond(conn, 403, json: ["ok": false, "error": "wrong pairing code or locked"])
            }
            return respond(conn, 200, json: statusJSON())
        case ("POST", "/upload"):
            guard authorize(request.codeCandidates) else {
                return respond(conn, 403, json: ["ok": false, "error": "wrong pairing code or locked"])
            }
            guard let rawPath = request.query["path"], !rawPath.isEmpty,
                  let relative = Self.safeRelativePath(rawPath) else {
                return respond(conn, 400, json: ["ok": false, "error": "bad path"])
            }
            let declared: Int64?
            if let sizeText = request.query["size"] {
                guard let value = Int64(sizeText), value >= 0 else {
                    return respond(conn, 400, json: ["ok": false, "error": "bad size"])
                }
                declared = value
            } else {
                declared = nil
            }
            let contentLength = request.headers["content-length"].flatMap { Int64($0) }
            let length = declared ?? contentLength ?? 0
            guard length >= 0, length <= Self.maxFileSize else {
                return respond(conn, 400, json: ["ok": false, "error": "bad length"])
            }
            if let contentLength, let declared, contentLength != declared {
                return respond(conn, 400, json: ["ok": false, "error": "length mismatch"])
            }
            return receiveFile(conn, relative: relative, length: length, initialBody: initialBody)
        default:
            guard request.path.hasPrefix("/") else {
                return respond(conn, 400, json: ["ok": false, "error": "bad request"])
            }
            return respond(conn, 404, json: ["ok": false, "error": "not found"])
        }
    }

    // MARK: - info / status

    private func infoJSON() -> [String: Any] {
        let root = GamePaths.transferTarget
        let free = Self.freeSpace(at: root)
        return [
            "app": "Clannad",
            "protocol": Self.protocolVersion,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            "root": root.path,
            "freeBytes": free,
        ]
    }

    /// Free space in bytes, with fallbacks the file-system APIs need on
    /// different platforms (the simulator reports no "important usage" value).
    private static func freeSpace(at url: URL) -> Int64 {
        if let value = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            return value
        }
        if let value = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity {
            return Int64(value)
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private func statusJSON() -> [String: Any] {
        let root = GamePaths.transferTarget
        var files: [[String: Any]] = []
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                let relative = Self.relativePath(of: url, under: root)
                guard !relative.isEmpty, Self.isIncludedInStatus(relative) else { continue }
                files.append(["path": relative, "size": values?.fileSize ?? 0])
            }
        }
        files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        return ["files": files]
    }

    /// App-managed save data is not part of the transfer inventory.
    private static func isIncludedInStatus(_ relative: String) -> Bool {
        !relative.hasPrefix("\(GamePaths.saveDirectoryName)/")
            && relative != GamePaths.saveDirectoryName
            && !relative.hasSuffix(".part")
    }

    // MARK: - receiving a file

    /// A file of the game folder: any extension of the shipped data tree, or
    /// the extensionless `LICENSE` file.  This is a safety filter (no scripts,
    /// no dot files, no paths), not a content check.
    static let allowedExtensions: Set<String> = [
        "pck", "dat", "ini", "exe", "dll", "vdf", "ico", "txt", "sav", "bmp",
        "g00", "nwa", "ovk", "wav", "ogg", "mp3", "wmv", "omv", "gan", "dbs",
        "cgm", "ttf", "otf", "pak", "json", "bin", "png", "jpg", "jpeg", "webp",
        "dds", "avi", "mp4", "mpg", "mpeg", "wma", "s", "lst", "toml", "tcc",
    ]
    static let allowedExtensionless: Set<String> = ["LICENSE", "README", "NOTICE"]
    static let maxFileSize: Int64 = 8 << 30

    /// Returns the normalized relative path, or nil when the name is unsafe.
    static func safeRelativePath(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count < 1024, !raw.hasPrefix("/"), !raw.hasPrefix("~") else { return nil }
        let pieces = raw.components(separatedBy: "/")
        guard !pieces.isEmpty else { return nil }
        for piece in pieces {
            guard !piece.isEmpty, piece != ".", piece != "..", !piece.hasPrefix("."),
                  !piece.contains("\\"), !piece.contains(":"), !piece.contains("\0") else { return nil }
        }
        let name = pieces.last ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            guard allowedExtensionless.contains(name) else { return nil }
        } else if !allowedExtensions.contains(ext) {
            return nil
        }
        return pieces.joined(separator: "/")
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return "" }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func receiveFile(_ conn: NWConnection, relative: String, length: Int64, initialBody: Data) {
        let fm = FileManager.default
        let root = GamePaths.transferTarget
        let final = root.appendingPathComponent(relative)
        let directory = final.deletingLastPathComponent()
        let partial = directory.appendingPathComponent(".\(final.lastPathComponent).part")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            fm.createFile(atPath: partial.path, contents: nil)
        } catch {
            return respond(conn, 500, json: ["ok": false, "error": "cannot create file"])
        }
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            return respond(conn, 500, json: ["ok": false, "error": "cannot write"])
        }
        var written: Int64 = 0
        var failed = false

        func write(_ data: Data) -> Bool {
            guard !failed else { return false }
            do { try handle.write(contentsOf: data) } catch {
                failed = true
                return false
            }
            written += Int64(data.count)
            DispatchQueue.main.async { self.bytesReceived += Int64(data.count) }
            return true
        }

        func finish(ok: Bool) {
            try? handle.close()
            if ok && written == length {
                do {
                    if fm.fileExists(atPath: final.path) {
                        try fm.removeItem(at: final)
                    }
                    try fm.moveItem(at: partial, to: final)
                } catch {
                    try? fm.removeItem(at: partial)
                    respond(conn, 500, json: ["ok": false, "error": "cannot rename"])
                    return
                }
                DispatchQueue.main.async {
                    self.lastEvent = "已接收 \(relative)（\(ByteCountFormatter.string(fromByteCount: length, countStyle: .file))）"
                    self.onFilesChanged?()
                }
                respond(conn, 200, json: ["ok": true, "path": relative])
            } else {
                try? fm.removeItem(at: partial)
                let code = written == length ? 500 : 409
                respond(conn, code, json: ["ok": false, "error": "written size mismatch",
                                           "expected": length, "written": written])
            }
        }

        func next() {
            if written >= length { return finish(ok: true) }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data, !data.isEmpty {
                    let remaining = length - written
                    if remaining > 0, !write(data.prefix(Int(remaining))) {
                        return finish(ok: false)
                    }
                }
                if error != nil || (complete && written < length) { return finish(ok: false) }
                next()
            }
        }

        if !initialBody.isEmpty {
            let remaining = max(0, length - written)
            if remaining > 0, !write(initialBody.prefix(Int(remaining))) {
                return finish(ok: false)
            }
            if initialBody.count > Int(length) {
                return finish(ok: false)
            }
        }
        next()
    }

    // MARK: - responses

    private func respond(_ conn: NWConnection, _ status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 500: "Internal Server Error"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}
