// FileXfer.swift: files dropped on the viewer window land in ~/Desktop.
// Flow (vd_agent.h): client FILE_XFER_START {id, key-file text} -> agent STATUS CAN_SEND_DATA ->
// client FILE_XFER_DATA {id, size, bytes}... -> agent STATUS SUCCESS. Either side may send
// STATUS CANCELLED/ERROR instead. spice-gtk 0.42 does not: when the user cancels it just stops
// sending DATA, so a transfer with no data for `idleTimeout` seconds is dropped and its partial
// file deleted.
//
// Everything runs on its own serial queue, never the main queue. macOS lets the agent create
// files in ~/Desktop without a privacy (TCC) prompt (reading the folder would prompt), but if a
// prompt ever did appear, open() would block until it is answered; only file transfers wait then.

import Foundation

final class FileXfer {
    private struct Transfer {
        let path: String
        let handle: FileHandle
        let size: UInt64
        var received: UInt64
        var lastData: Date
    }

    static let idleTimeout: TimeInterval = 20

    let directory: String
    let queue = DispatchQueue(label: "spice-agent.files")
    /// Sends a FILE_XFER_STATUS message body.
    var sendStatus: ((Data) -> Void)?
    /// Whether the connected client announced VD_AGENT_CAP_FILE_XFER_DETAILED_ERRORS.
    private var clientWantsDetails = false
    private var transfers: [UInt32: Transfer] = [:]
    private var sweepTimer: DispatchSourceTimer?   // runs only while transfers are in progress

    init(directory: String) { self.directory = directory }

    private func status(_ id: UInt32, _ result: UInt32, extra: Data = Data()) {
        var d = Data()
        d.appendLE(id)
        d.appendLE(result)
        if clientWantsDetails { d.append(extra) }
        sendStatus?(d)
    }

    // Entry points: safe from any thread.
    func start(_ data: Data) { queue.async { self.doStart(data) } }
    func data(_ data: Data) { queue.async { self.doData(data) } }
    func clientStatus(_ data: Data) { queue.async { self.doClientStatus(data) } }
    func abortAll() { queue.async { self.doAbortAll() } }
    func setClientWantsDetails(_ v: Bool) { queue.async { self.clientWantsDetails = v } }

    private func doStart(_ data: Data) {
        var r = ByteReader(data)
        guard let id = r.u32() else { return }
        var text = r.rest()
        while text.last == 0 { text.removeLast() }
        let info = FileXfer.parseKeyFile(String(decoding: text, as: UTF8.self))
        guard let rawName = info["name"], let sizeStr = info["size"], let size = UInt64(sizeStr) else {
            log("file xfer \(id): bad start message")
            status(id, XferStatus.error)
            return
        }
        if transfers[id] != nil {
            log("file xfer \(id): duplicate id")
            status(id, XferStatus.error)
            return
        }
        let free = FileXfer.freeSpace(directory)
        if let free, size > free {
            log("file xfer \(id): \(size) bytes but only \(free) free")
            var extra = Data()
            extra.appendLE(free)
            status(id, XferStatus.notEnoughSpace, extra: extra)
            return
        }
        guard let (path, fd) = FileXfer.createUnique(directory: directory, name: FileXfer.sanitize(rawName)) else {
            log("file xfer \(id): cannot create a file for '\(rawName)' in \(directory)")
            status(id, XferStatus.error)
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        log("file xfer \(id): receiving \(size) bytes into \(path)")
        if size == 0 {
            try? handle.close()
            status(id, XferStatus.success)
            return
        }
        transfers[id] = Transfer(path: path, handle: handle, size: size, received: 0, lastData: Date())
        status(id, XferStatus.canSendData)
        updateSweep()
    }

    private func doData(_ data: Data) {
        var r = ByteReader(data)
        guard let id = r.u32(), let len = r.u64() else { return }
        guard var t = transfers[id] else { return }   // cancelled or unknown: ignore late data
        let bytes = r.rest()
        guard UInt64(bytes.count) == len, t.received + len <= t.size else {
            log("file xfer \(id): data does not match the announced size")
            fail(id, notify: true)
            return
        }
        do {
            try t.handle.write(contentsOf: bytes)
        } catch {
            log("file xfer \(id): write failed: \(error)")
            fail(id, notify: true)
            return
        }
        t.received += len
        t.lastData = Date()
        if t.received == t.size {
            try? t.handle.close()
            transfers[id] = nil
            log("file xfer \(id): done")
            status(id, XferStatus.success)
            updateSweep()
        } else {
            transfers[id] = t
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

    /// Client went away: every transfer in progress is incomplete.
    private func doAbortAll() {
        for id in Array(transfers.keys) { fail(id, notify: false) }
    }

    private func fail(_ id: UInt32, notify: Bool) {
        guard let t = transfers.removeValue(forKey: id) else { return }
        try? t.handle.close()
        unlink(t.path)
        if notify { status(id, XferStatus.error) }
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
            fail(id, notify: true)
        }
    }

    // MARK: helpers

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

    /// Keep only the last path component; no hidden or empty names, no control characters.
    static func sanitize(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent
        n = String(n.unicodeScalars.filter { $0.value >= 0x20 && $0 != "/" && $0 != ":" }.map(Character.init))
        while n.hasPrefix(".") { n.removeFirst() }
        n = n.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "dropped-file" }
        if n.utf8.count > 200 {
            let ext = (n as NSString).pathExtension
            var base = (n as NSString).deletingPathExtension
            while base.utf8.count + ext.utf8.count > 190 { base.removeLast() }
            n = ext.isEmpty ? base : base + "." + ext
        }
        return n
    }

    /// Create `name` in `directory`, or "base (1).ext", "base (2).ext"... if it exists. O_EXCL
    /// means an existing file is never overwritten, even if one appears in the meantime.
    static func createUnique(directory: String, name: String) -> (String, Int32)? {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for i in 0..<1000 {
            let candidate = i == 0 ? name : (ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            let path = (directory as NSString).appendingPathComponent(candidate)
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if fd >= 0 { return (path, fd) }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    static func freeSpace(_ directory: String) -> UInt64? {
        var s = statfs()
        guard statfs(directory, &s) == 0 else { return nil }
        return UInt64(s.f_bavail) * UInt64(s.f_bsize)
    }
}
