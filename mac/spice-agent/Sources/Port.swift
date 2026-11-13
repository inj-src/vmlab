// Port.swift: the agent's end of the link to the client. A Unix socket the agent listens on; the
// host connects to it through SSH (`ssh -L`), so sshd is all that carries the bytes. One client
// at a time: a new connection replaces the one before it. Reads use a kqueue-backed dispatch
// source (no polling, no thread parked in read); whole messages are written on a serial queue.
//
// It was the virtio console until 2026-11-13. macOS stopped reading that device at random
// after some tens of megabytes, and nothing short of a guest restart brought it back.

import Foundation

final class Port {
    let path: String
    /// Reads, parsing, accept and close all happen here.
    let ioQueue = DispatchQueue(label: "spice-agent.io")
    /// Whole messages are written here, one after another, so chunks of two messages never mix.
    private let writeQueue = DispatchQueue(label: "spice-agent.write")

    /// Called on ioQueue when a client has connected.
    var onOpen: (() -> Void)?
    /// Called on ioQueue with each batch of bytes read.
    var onBytes: ((UnsafeRawBufferPointer) throws -> Void)?
    /// Called on ioQueue after the client's connection was closed.
    var onClose: (() -> Void)?

    private var lockFD: Int32 = -1         // held for life: one agent per socket
    private var listener: DispatchSourceRead?
    private var fd: Int32 = -1             // the client's connection; owned by ioQueue
    private var writeFD: Int32 = -1        // owned by writeQueue
    private var source: DispatchSourceRead?
    private var buffer = [UInt8](repeating: 0, count: 1 << 18)
    private var failureLogged = false
    private let activityLock = NSLock()
    private var lastRead = DispatchTime.now()

    /// When bytes last arrived from the client (any thread).
    var lastReadTime: DispatchTime {
        activityLock.lock(); defer { activityLock.unlock() }
        return lastRead
    }

    init(path: String) { self.path = path }

    func start() { ioQueue.async { self.listen() } }

    private func listen() {
        if let why = bindSocket() {
            if !failureLogged { log("cannot listen on \(path): \(why); retrying every 3 s") }
            failureLogged = true
            ioQueue.asyncAfter(deadline: .now() + 3) { self.listen() }
        }
    }

    /// Nil when the socket is listening, or why it is not.
    private func bindSocket() -> String? {
        func problem(_ what: String) -> String { "\(what): \(String(cString: strerror(errno)))" }
        // A second agent (say, one started by hand) would take the socket's name from the first
        // and leave it listening on nothing. The lock makes the second one wait instead.
        if lockFD < 0 {
            let l = Darwin.open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard l >= 0 else { return problem("lock file") }
            guard flock(l, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(l)
                return "another agent has it"
            }
            lockFD = l
        }
        var addr = sockaddr_un()
        let name = Array(path.utf8)
        guard name.count < MemoryLayout.size(ofValue: addr.sun_path) else { return "the path is too long for a socket" }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: name) }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return problem("socket") }
        unlink(path)   // a socket left by an agent that was killed
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(s, 4) == 0, configure(s) else {
            let why = problem("bind")
            Darwin.close(s)
            return why
        }
        let l = DispatchSource.makeReadSource(fileDescriptor: s, queue: ioQueue)
        l.setEventHandler { [weak self] in self?.acceptClients(s) }
        l.resume()
        listener = l
        failureLogged = false
        log("listening on \(path)")
        return nil
    }

    /// Non-blocking, not inherited by child processes, and a write to a closed connection is an
    /// error, not a signal.
    private func configure(_ f: Int32) -> Bool {
        var one: Int32 = 1
        return fcntl(f, F_SETFL, fcntl(f, F_GETFL) | O_NONBLOCK) == 0 && fcntl(f, F_SETFD, FD_CLOEXEC) == 0
            && setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func acceptClients(_ s: Int32) {
        while true {
            let c = Darwin.accept(s, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN: nobody else is waiting
            }
            guard configure(c) else {
                Darwin.close(c)
                continue
            }
            // The newest connection is the live one: an older one may be what a client that
            // was killed left behind.
            if fd >= 0 { close(why: "a new client connected") }
            fd = c
            writeQueue.sync { writeFD = c }
            let r = DispatchSource.makeReadSource(fileDescriptor: c, queue: ioQueue)
            r.setEventHandler { [weak self] in self?.readAvailable() }
            // libdispatch needs the descriptor open until the source is fully cancelled.
            r.setCancelHandler { Darwin.close(c) }
            source = r
            r.resume()
            log("a client connected")
            onOpen?()
        }
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                activityLock.lock(); lastRead = .now(); activityLock.unlock()
                do {
                    try buffer.withUnsafeBytes { try onBytes?(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                } catch {
                    close(why: "protocol error: \(error)")
                    return
                }
                if n < buffer.count { return }   // drained; the source fires again on new data
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            close(why: n == 0 ? "the client closed the connection" : "read failed: \(String(cString: strerror(errno)))")
            return
        }
    }

    /// Close the client's connection; the socket goes on listening and the client connects
    /// again. Must run on ioQueue.
    private func close(why: String) {
        guard fd >= 0 else { return }
        let f = fd
        fd = -1
        // A write waiting for room fails at once after the shutdown. Then stop writes: this
        // waits for the one in progress, and later ones are dropped. Then cancel the read
        // source; its cancel handler closes the descriptor, so no write can land on a reused
        // descriptor number.
        shutdown(f, SHUT_RDWR)
        writeQueue.sync { writeFD = -1 }
        source?.cancel()
        source = nil
        log("connection closed: \(why)")
        onClose?()
    }

    /// Queue one encoded message (one or more chunks) for writing. Safe from any thread.
    func write(_ bytes: Data) {
        writeQueue.async {
            guard self.writeFD >= 0 else { return }
            let f = self.writeFD
            if !self.writeAll(f, bytes) {
                // A partly written message leaves the client's parser mid-message. Nothing more
                // may be written to this stream: close it, and the client's next connection
                // starts a new one.
                self.writeFD = -1
                self.ioQueue.async { if self.fd == f { self.close(why: "write failed") } }
            }
        }
    }

    private func writeAll(_ f: Int32, _ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var off = 0
            var stalledSince: Date?
            while off < raw.count {
                let n = Darwin.write(f, raw.baseAddress! + off, raw.count - off)
                if n > 0 {
                    off += n
                    stalledSince = nil
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN {
                    let start = stalledSince ?? Date()
                    stalledSince = start
                    if Date().timeIntervalSince(start) > 30 {
                        log("the client took nothing for 30 s; giving up on this message")
                        return false
                    }
                    var pfd = pollfd(fd: f, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1000)
                    continue
                }
                log("write failed: \(String(cString: strerror(errno)))")
                return false
            }
            return true
        }
    }
}
