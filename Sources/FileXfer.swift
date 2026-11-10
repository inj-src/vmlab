// FileXfer.swift: files dropped on the viewer window land in ~/Desktop.
// Flow (vd_agent.h): client FILE_XFER_START {id, key-file text} -> agent STATUS CAN_SEND_DATA ->
// client FILE_XFER_DATA {id, size, bytes}... -> agent STATUS SUCCESS. Either side may send
// STATUS CANCELLED/ERROR instead. spice-gtk 0.42 does not: when the user cancels it just stops
// sending DATA, so a transfer with no data for `idleTimeout` seconds is dropped.
//
// Each file is received into a private staging directory (~/Library/Caches/vmlab-spice-agent/
// partial) and moved to its final name only when complete, with an exclusive rename, so a
// partial file never sits on the Desktop under a real name, an existing file is never
// overwritten, and leftovers from a killed agent are removed the next time it opens the port.
//
// Everything runs on its own serial queue, never the main queue. macOS lets the agent create
// files in ~/Desktop without a privacy (TCC) prompt (reading the folder would prompt), but if a
// prompt ever did appear, only file transfers would wait for it.

import Foundation

final class FileXfer {
    private struct Transfer {
        let stagePath: String
        let name: String
        let handle: FileHandle
        let size: UInt64
        let generation: Int
        var received: UInt64
        var lastData: Date
    }

    static let idleTimeout: TimeInterval = 20
    /// More concurrent transfers than this are refused (each holds a file descriptor).
    static let maxActive = 32
    /// Free space a transfer must leave on the volume.
    static let reserve: UInt64 = 512 << 20

    let directory: String
    let stageDir: String
    let queue = DispatchQueue(label: "spice-agent.files")
    /// Sends a FILE_XFER_STATUS message body.
    var sendStatus: ((Data) -> Void)?
    /// Whether the connected client announced VD_AGENT_CAP_FILE_XFER_DETAILED_ERRORS.
    private var clientWantsDetails = false
    private var transfers: [UInt32: Transfer] = [:]
    private var sweepTimer: DispatchSourceTimer?   // runs only while transfers are in progress

    // Client generation, bumped the moment a client goes away. Work queued for that client (for
    // example behind a slow disk write) then never sends a status to the next client.
    private let genLock = NSLock()
    private var currentGeneration = 0
    private var generation: Int {
        genLock.lock(); defer { genLock.unlock() }
        return currentGeneration
    }

    /// `stageDir` must belong to this agent alone: every file in it is deleted on port open.
    init(directory: String, stageDir: String) {
        self.directory = directory
        self.stageDir = stageDir
    }

    // Entry points: safe from any thread.
    func start(_ data: Data) { let g = generation; queue.async { if g == self.generation { self.doStart(data, g) } } }
    func data(_ data: Data) { let g = generation; queue.async { if g == self.generation { self.doData(data) } } }
    func clientStatus(_ data: Data) { let g = generation; queue.async { if g == self.generation { self.doClientStatus(data) } } }
    func setClientWantsDetails(_ v: Bool) { queue.async { self.clientWantsDetails = v } }
    /// The client went away: every transfer in progress is incomplete.
    func abortAll() {
        genLock.lock(); currentGeneration += 1; genLock.unlock()
        queue.async { for id in Array(self.transfers.keys) { self.fail(id, notify: false) } }
    }
    /// Remove staging files left by an agent that was killed mid-transfer. Called on port open,
    /// when no transfer can be in progress.
    func cleanStage() {
        queue.async {
            guard self.transfers.isEmpty,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: self.stageDir) else { return }
            for n in names { unlink((self.stageDir as NSString).appendingPathComponent(n)) }
            if !names.isEmpty { log("removed \(names.count) partial file(s) left by an earlier run") }
        }
    }

    // MARK: status replies

    private func status(_ id: UInt32, _ result: UInt32, generation g: Int, extra: Data = Data()) {
        guard g == generation else { return }   // that client is gone
        var d = Data()
        d.appendLE(id)
        d.appendLE(result)
        if clientWantsDetails { d.append(extra) }
        sendStatus?(d)
    }

    /// STATUS ERROR with a VDAgentFileXferStatusError {u8 GLIB_IO; u32 GIOErrorEnum} when the
    /// client asked for details.
    private func sendError(_ id: UInt32, errno e: Int32, generation g: Int) {
        let code: UInt32
        switch e {
        case ENOSPC, EDQUOT: code = 12            // G_IO_ERROR_NO_SPACE
        case EACCES, EPERM: code = 14             // G_IO_ERROR_PERMISSION_DENIED
        case EINVAL: code = 13                    // G_IO_ERROR_INVALID_ARGUMENT
        case EMFILE, ENFILE: code = 31            // G_IO_ERROR_TOO_MANY_OPEN_FILES
        case ETIMEDOUT: code = 24                 // G_IO_ERROR_TIMED_OUT
        default: code = 0                         // G_IO_ERROR_FAILED
        }
        var extra = Data([0])                     // VD_AGENT_FILE_XFER_STATUS_ERROR_GLIB_IO
        extra.appendLE(code)
        status(id, XferStatus.error, generation: g, extra: extra)
    }

    // MARK: work (files queue)

    private func doStart(_ data: Data, _ g: Int) {
        var r = ByteReader(data)
        guard let id = r.u32() else { return }
        var text = r.rest()
        while text.last == 0 { text.removeLast() }
        let info = FileXfer.parseKeyFile(String(decoding: text, as: UTF8.self))
        guard let rawName = info["name"], let sizeStr = info["size"], let size = UInt64(sizeStr) else {
            log("file xfer \(id): bad start message")
            sendError(id, errno: EINVAL, generation: g)
            return
        }
        if transfers[id] != nil {
            log("file xfer \(id): duplicate id")
            sendError(id, errno: EINVAL, generation: g)
            return
        }
        if transfers.count >= FileXfer.maxActive {
            log("file xfer \(id): \(transfers.count) transfers already in progress; refused")
            sendError(id, errno: EMFILE, generation: g)
            return
        }
        try? FileManager.default.createDirectory(atPath: stageDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Bytes still to arrive for the other transfers count as used.
        let pending = transfers.values.reduce(UInt64(0)) { $0 + ($1.size - $1.received) }
        let free = [FileXfer.freeSpace(stageDir), FileXfer.freeSpace(directory)].compactMap { $0 }.min()
        if let free {
            let usable = free > pending + FileXfer.reserve ? free - pending - FileXfer.reserve : 0
            if size > usable {
                log("file xfer \(id): \(size) bytes but only \(usable) usable (\(free) free)")
                var extra = Data()
                extra.appendLE(usable)
                status(id, XferStatus.notEnoughSpace, generation: g, extra: extra)
                return
            }
        }
        let name = FileXfer.sanitize(rawName)
        let stagePath = (stageDir as NSString).appendingPathComponent("\(id)-\(UUID().uuidString)")
        let fd = open(stagePath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let e = errno
            log("file xfer \(id): cannot create \(stagePath): \(String(cString: strerror(e)))")
            sendError(id, errno: e, generation: g)
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        log("file xfer \(id): receiving \(size) bytes for '\(name)'")
        transfers[id] = Transfer(stagePath: stagePath, name: name, handle: handle, size: size,
                                 generation: g, received: 0, lastData: Date())
        if size == 0 {
            complete(id)
            return
        }
        status(id, XferStatus.canSendData, generation: g)
        updateSweep()
    }

    private func doData(_ data: Data) {
        var r = ByteReader(data)
        guard let id = r.u32(), let len = r.u64() else { return }
        guard var t = transfers[id] else { return }   // cancelled or unknown: ignore late data
        let bytes = r.rest()
        guard UInt64(bytes.count) == len, t.received + len <= t.size else {
            log("file xfer \(id): data does not match the announced size")
            fail(id, notify: true, errno: EINVAL)
            return
        }
        guard len > 0 else { return }   // no progress: does not keep the transfer alive
        do {
            try t.handle.write(contentsOf: bytes)
        } catch {
            log("file xfer \(id): write failed: \(error)")
            fail(id, notify: true, errno: Int32((error as NSError).code == NSFileWriteOutOfSpaceError ? ENOSPC : EIO))
            return
        }
        t.received += len
        t.lastData = Date()
        transfers[id] = t
        if t.received == t.size { complete(id) }
    }

    /// All bytes are in: close the staging file and move it to its final name.
    private func complete(_ id: UInt32) {
        guard let t = transfers.removeValue(forKey: id) else { return }
        updateSweep()
        do { try t.handle.close() } catch {
            log("file xfer \(id): close failed: \(error)")
            unlink(t.stagePath)
            sendError(id, errno: EIO, generation: t.generation)
            return
        }
        switch FileXfer.publish(t.stagePath, directory: directory, name: t.name) {
        case .success(let path):
            log("file xfer \(id): done: \(path)")
            status(id, XferStatus.success, generation: t.generation)
        case .failure(let e):
            log("file xfer \(id): cannot move it into \(directory): \(String(cString: strerror(e.code)))")
            unlink(t.stagePath)
            sendError(id, errno: e.code, generation: t.generation)
        }
    }

    /// STATUS from the client: it cancelled or hit an error on its side.
    private func doClientStatus(_ data: Data) {
        var r = ByteReader(data)
        guard let id = r.u32(), let result = r.u32() else { return }
        guard transfers[id] != nil else { return }
        log("file xfer \(id): client sent status \(result); discarding the partial file")
        fail(id, notify: false)
    }

    private func fail(_ id: UInt32, notify: Bool, errno e: Int32 = 0) {
        guard let t = transfers.removeValue(forKey: id) else { return }
        try? t.handle.close()
        unlink(t.stagePath)
        if notify { sendError(id, errno: e, generation: t.generation) }
        updateSweep()
    }

    private func updateSweep() {
        if transfers.isEmpty {
            sweepTimer?.cancel()
            sweepTimer = nil
        } else if sweepTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            t.setEventHandler { [unowned self] in self.sweep() }
            t.resume()
            sweepTimer = t
        }
    }

    private func sweep() {
        let now = Date()
        for (id, t) in transfers where now.timeIntervalSince(t.lastData) > FileXfer.idleTimeout {
            log("file xfer \(id): no data for \(Int(FileXfer.idleTimeout)) s (cancelled by the client?); discarding the partial file")
            fail(id, notify: true, errno: ETIMEDOUT)
        }
    }

    // MARK: helpers

    struct Errno: Error { let code: Int32 }

    /// Move a finished staging file to `name` in `directory`, or "base (1).ext", "base (2).ext"...
    /// if that exists. RENAME_EXCL (or COPYFILE_EXCL across volumes) never replaces a file, even
    /// one that appears in the meantime.
    static func publish(_ src: String, directory: String, name: String) -> Result<String, Errno> {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        for i in 0..<1000 {
            let candidate = i == 0 ? name : (ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            let dst = (directory as NSString).appendingPathComponent(candidate)
            if renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0 { return .success(dst) }
            var e = errno
            if e == EXDEV {
                if copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 {
                    unlink(src)
                    return .success(dst)
                }
                e = errno
            }
            if e != EEXIST { return .failure(Errno(code: e)) }
        }
        return .failure(Errno(code: EEXIST))
    }

    /// Minimal GKeyFile reader: `key=value` lines, with \s \n \t \r \\ escapes in values.
    static func parseKeyFile(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var inGroup = false
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { inGroup = (l == "[vdagent-file-xfer]"); continue }
            guard inGroup, !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let key = l[..<eq].trimmingCharacters(in: .whitespaces)
            // Only leading whitespace after '=' is insignificant; take the raw value from `line`.
            let rawValue = line[line.index(after: line.firstIndex(of: "=")!)...]
            out[key] = unescape(String(rawValue.drop(while: { $0 == " " || $0 == "\t" })))
        }
        return out
    }

    static func unescape(_ v: String) -> String {
        var out = ""
        var it = v.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "s": out.append(" ")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }

    /// Keep only the last path component; no hidden or empty names, no control or invisible
    /// formatting characters, at most 200 bytes.
    static func sanitize(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        // C0/C1 controls, DEL, '/' and ':', and format characters such as U+202E RIGHT-TO-LEFT
        // OVERRIDE (which can make "cod.exe" display as "exe.doc").
        let kept = last.unicodeScalars.filter { s in
            !(s.value < 0x20 || (0x7f...0x9f).contains(s.value) || s == "/" || s == ":"
              || s.properties.generalCategory == .format)
        }
        var n = String(String.UnicodeScalarView(kept))
        if n.utf8.count > 200 {
            // APFS allows 255 bytes; leave room for " (999)". Keep the extension only if short.
            var ext = (n as NSString).pathExtension
            var base = (n as NSString).deletingPathExtension
            if ext.utf8.count > 16 { ext = ""; base = n }
            while !base.isEmpty && base.utf8.count + ext.utf8.count > 190 { base.removeLast() }
            n = ext.isEmpty ? base : base + "." + ext
        }
        n = n.trimmingCharacters(in: .whitespaces)
        while n.hasPrefix(".") {
            n.removeFirst()
            n = n.trimmingCharacters(in: .whitespaces)
        }
        return n.isEmpty ? "dropped-file" : n
    }

    static func freeSpace(_ directory: String) -> UInt64? {
        var s = statfs()
        guard statfs(directory, &s) == 0 else { return nil }
        return UInt64(s.f_bavail) * UInt64(s.f_bsize)
    }
}
