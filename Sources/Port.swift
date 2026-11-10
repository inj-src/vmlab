// Port.swift: the virtio console device. Opens it in raw mode, reads with a kqueue-backed
// dispatch source (no polling, no thread parked in read), writes whole messages on a serial
// queue, and reopens it when it is missing or closes.

import Foundation

final class SerialPort {
    let path: String
    /// Reads, parsing, open and close all happen here.
    let ioQueue = DispatchQueue(label: "spice-agent.io")
    /// Whole messages are written here, one after another, so chunks of two messages never mix.
    private let writeQueue = DispatchQueue(label: "spice-agent.write")

    /// Called on ioQueue after the device is open and configured.
    var onOpen: (() -> Void)?
    /// Called on ioQueue with each batch of bytes read.
    var onBytes: ((UnsafeRawBufferPointer) throws -> Void)?
    /// Called on ioQueue after the device was closed (before a reopen is scheduled).
    var onClose: (() -> Void)?

    private var fd: Int32 = -1             // owned by ioQueue
    private var writeFD: Int32 = -1        // owned by writeQueue
    private var source: DispatchSourceRead?
    private var buffer = [UInt8](repeating: 0, count: 65536)
    private var missingLogged = false

    init(path: String) { self.path = path }

    func start() { ioQueue.async { self.open() } }

    private func open() {
        precondition(fd < 0)
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard f >= 0 else {
            let e = errno
            if !missingLogged { log("cannot open \(path): \(String(cString: strerror(e))); retrying every 3 s") }
            missingLogged = true
            ioQueue.asyncAfter(deadline: .now() + 3) { self.open() }
            return
        }
        missingLogged = false
        if verbose { log("open() returned") }
        if let err = makeRaw(f) {
            log("cannot configure \(path): \(err)")
            Darwin.close(f)
            ioQueue.asyncAfter(deadline: .now() + 3) { self.open() }
            return
        }
        // No tcflush here: spice-server starts a fresh chunk stream whenever the guest opens the
        // port, and flushing the input queue of the macOS virtio console stalled host->guest
        // traffic after an agent restart.
        fd = f
        writeQueue.sync { writeFD = f }
        let s = DispatchSource.makeReadSource(fileDescriptor: f, queue: ioQueue)
        s.setEventHandler { [weak self] in self?.readAvailable() }
        source = s
        s.resume()
        log("opened \(path)")
        onOpen?()
    }

    /// Raw 8-bit-clean mode: no echo, no line discipline, no CR/LF translation, no XON/XOFF,
    /// no hardware flow control. Without this, payload bytes 0x11/0x13/0x0d get eaten or changed.
    private func makeRaw(_ f: Int32) -> String? {
        var t = termios()
        guard tcgetattr(f, &t) == 0 else { return String(cString: strerror(errno)) }
        cfmakeraw(&t)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | ICRNL | INLCR | IGNCR | ISTRIP | INPCK | PARMRK)
        t.c_oflag &= ~tcflag_t(OPOST)
        t.c_cflag &= ~tcflag_t(CRTSCTS | PARENB | CSIZE | CSTOPB)
        t.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        t.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(f, TCSANOW, &t) == 0 else { return String(cString: strerror(errno)) }
        return nil
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                do {
                    try buffer.withUnsafeBytes { try onBytes?(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                } catch {
                    log("protocol error: \(error); reopening the port")
                    reopen(after: 1)
                    return
                }
                if n < buffer.count { return }   // drained; the source fires again on new data
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            let why = n == 0 ? "end of file" : String(cString: strerror(errno))
            log("read from \(path) failed: \(why); reopening")
            reopen(after: 2)
            return
        }
    }

    /// Close and reopen later. Must run on ioQueue.
    func reopen(after delay: Double) {
        guard fd >= 0 else { return }
        let f = fd
        fd = -1
        source?.cancel()
        source = nil
        // Close on the write queue so a write in progress finishes (or fails) first and no
        // later write can land on a reused descriptor number.
        writeQueue.sync {
            writeFD = -1
            Darwin.close(f)
        }
        onClose?()
        ioQueue.asyncAfter(deadline: .now() + delay) { if self.fd < 0 { self.open() } }
    }

    /// Queue one encoded message (one or more chunks) for writing. Safe from any thread.
    func write(_ bytes: Data) {
        writeQueue.async {
            guard self.writeFD >= 0 else { return }
            if !self.writeAll(self.writeFD, bytes) {
                // A partly written message leaves spice-server's parser mid-message. Closing the
                // port makes it reset, and the reopen announces our capabilities again.
                let f = self.writeFD
                self.ioQueue.async { if self.fd == f { self.reopen(after: 1) } }
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
                        log("write to \(path) stalled for 30 s; giving up on this message")
                        return false
                    }
                    var pfd = pollfd(fd: f, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1000)
                    continue
                }
                log("write to \(path) failed: \(String(cString: strerror(errno)))")
                return false
            }
            return true
        }
    }
}
