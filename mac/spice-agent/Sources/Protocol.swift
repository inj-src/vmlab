// Protocol.swift: SPICE vdagent wire format, written from spice-protocol's spice/vd_agent.h
// (copy in protocol/vd_agent.h). Everything on the wire is packed little-endian.
//
// The virtio port carries a stream of chunks: VDIChunkHeader { u32 port; u32 size } followed by
// `size` payload bytes (at most VD_AGENT_MAX_DATA_SIZE). The payloads of one port, concatenated,
// form a stream of messages: VDAgentMessage { u32 protocol; u32 type; u64 opaque; u32 size }
// followed by `size` data bytes. A message can span many chunks.

import Foundation

enum VDP {
    static let clientPort: UInt32 = 1   // VDP_CLIENT_PORT: messages to/from the SPICE client
    static let serverPort: UInt32 = 2   // VDP_SERVER_PORT: messages from spice-server itself
}

let vdAgentProtocol: UInt32 = 1          // VD_AGENT_PROTOCOL
let vdAgentMaxDataSize = 2048            // VD_AGENT_MAX_DATA_SIZE: payload bytes per chunk
let chunkHeaderSize = 8
let messageHeaderSize = 20

/// VD_AGENT_* message types (the enum in vd_agent.h, starting at 1).
enum MsgType {
    static let mouseState: UInt32 = 1
    static let monitorsConfig: UInt32 = 2
    static let reply: UInt32 = 3
    static let clipboard: UInt32 = 4
    static let displayConfig: UInt32 = 5
    static let announceCapabilities: UInt32 = 6
    static let clipboardGrab: UInt32 = 7
    static let clipboardRequest: UInt32 = 8
    static let clipboardRelease: UInt32 = 9
    static let fileXferStart: UInt32 = 10
    static let fileXferStatus: UInt32 = 11
    static let fileXferData: UInt32 = 12
    static let clientDisconnected: UInt32 = 13
    static let maxClipboard: UInt32 = 14
    static let audioVolumeSync: UInt32 = 15
    static let graphicsDeviceInfo: UInt32 = 16
}

/// VD_AGENT_CAP_* bit indexes.
enum Cap {
    static let mouseState = 0
    static let clipboard = 3
    static let clipboardByDemand = 5
    static let clipboardSelection = 6
    static let guestLineEndLF = 8
    static let maxClipboard = 10
    static let fileXferDisabled = 13
    static let fileXferDetailedErrors = 14
    static let clipboardNoReleaseOnRegrab = 16
    static let clipboardGrabSerial = 17
}

/// VD_AGENT_CLIPBOARD_* data types.
enum ClipType {
    static let none: UInt32 = 0
    static let utf8Text: UInt32 = 1
    static let png: UInt32 = 2
    static let bmp: UInt32 = 3
    static let tiff: UInt32 = 4
    static let jpg: UInt32 = 5
    static let fileList: UInt32 = 6
}

/// VD_AGENT_FILE_XFER_STATUS_* results.
enum XferStatus {
    static let canSendData: UInt32 = 0
    static let cancelled: UInt32 = 1
    static let error: UInt32 = 2
    static let success: UInt32 = 3
    static let notEnoughSpace: UInt32 = 4
    static let sessionLocked: UInt32 = 5
    static let agentNotConnected: UInt32 = 6
    static let disabled: UInt32 = 7
}

struct Caps: CustomStringConvertible {
    var words: [UInt32]
    init(words: [UInt32] = []) { self.words = words }
    init(bits: [Int]) {
        words = []
        for b in bits { set(b) }
    }
    func has(_ bit: Int) -> Bool {
        let w = bit / 32
        return w < words.count && words[w] & (1 << UInt32(bit % 32)) != 0
    }
    mutating func set(_ bit: Int) {
        while words.count <= bit / 32 { words.append(0) }
        words[bit / 32] |= 1 << UInt32(bit % 32)
    }
    var description: String { words.map { String(format: "0x%08x", $0) }.joined(separator: ",") }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: Int32) { appendLE(UInt32(bitPattern: v)) }
}

/// Bounds-checked little-endian reader over a Data value. Reads return nil past the end.
struct ByteReader {
    let data: Data
    private(set) var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }
    var remaining: Int { data.endIndex - offset }
    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
        offset += 4
        return v
    }
    mutating func u64() -> UInt64? {
        guard let lo = u32(), let hi = u32() else { return nil }
        return UInt64(lo) | UInt64(hi) << 32
    }
    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }
}

// MARK: - Encoding

struct AgentMessage {
    let port: UInt32
    let type: UInt32
    let data: Data
}

/// Serialise one message for the client port and split it into chunks.
func encodeMessage(type: UInt32, data: Data, port: UInt32 = VDP.clientPort) -> Data {
    let total = messageHeaderSize + data.count
    var msg = Data(capacity: total)
    msg.appendLE(vdAgentProtocol)
    msg.appendLE(type)
    msg.appendLE(UInt64(0))          // opaque
    msg.appendLE(UInt32(data.count))
    msg.append(data)
    let nChunks = (total + vdAgentMaxDataSize - 1) / vdAgentMaxDataSize
    var out = Data(capacity: total + nChunks * chunkHeaderSize)
    var off = 0
    while off < total {
        let n = Swift.min(vdAgentMaxDataSize, total - off)
        out.appendLE(port)
        out.appendLE(UInt32(n))
        out.append(msg[off..<(off + n)])
        off += n
    }
    return out
}

// MARK: - Decoding

enum ProtocolError: Error, CustomStringConvertible {
    case badPort(UInt32), badChunkSize(UInt32), badProtocol(UInt32)
    var description: String {
        switch self {
        case .badPort(let p): return "chunk for unknown port \(p)"
        case .badChunkSize(let s): return "oversized chunk (\(s) bytes)"
        case .badProtocol(let p): return "message with protocol \(p), expected \(vdAgentProtocol)"
        }
    }
}

/// Rebuilds the messages of one port from its chunk payloads, which can split anywhere.
final class MessageAssembler {
    let port: UInt32
    /// Messages bigger than this are read and thrown away instead of buffered.
    var maxMessageSize: Int
    private var header = Data()
    private var type: UInt32 = 0
    private var body = Data()
    private var want = 0          // body bytes still missing for the current message
    private var skipping = false
    private var inBody = false

    init(port: UInt32, maxMessageSize: Int) {
        self.port = port
        self.maxMessageSize = maxMessageSize
    }

    func reset() {
        header.removeAll(keepingCapacity: true)
        body = Data()
        want = 0
        inBody = false
        skipping = false
    }

    func feed(_ bytes: UnsafeRawBufferPointer, emit: (AgentMessage) -> Void) throws {
        var p = 0
        while p < bytes.count {
            if !inBody {
                let n = Swift.min(messageHeaderSize - header.count, bytes.count - p)
                header.append(contentsOf: bytes[p..<(p + n)])
                p += n
                guard header.count == messageHeaderSize else { break }
                var r = ByteReader(header)
                let proto = r.u32()!
                type = r.u32()!
                _ = r.u64()!
                let size = Int(r.u32()!)
                header.removeAll(keepingCapacity: true)
                guard proto == vdAgentProtocol else { throw ProtocolError.badProtocol(proto) }
                want = size
                skipping = size > maxMessageSize
                if skipping {
                    log("dropping message type \(type) on port \(port): \(size) bytes exceeds \(maxMessageSize)")
                }
                body = Data(capacity: skipping ? 0 : size)
                inBody = true
            }
            let n = Swift.min(want, bytes.count - p)
            if !skipping && n > 0 { body.append(contentsOf: bytes[p..<(p + n)]) }
            p += n
            want -= n
            if want == 0 {
                inBody = false
                if !skipping { emit(AgentMessage(port: port, type: type, data: body)) }
                body = Data()
                skipping = false
            }
        }
    }
}

/// Splits the raw byte stream from the device into chunks and routes each payload to its port.
final class ChunkReader {
    private var header = Data()
    private var port: UInt32 = 0
    private var remaining = 0
    let assemblers: [UInt32: MessageAssembler]

    init(maxMessageSize: Int) {
        assemblers = [
            VDP.clientPort: MessageAssembler(port: VDP.clientPort, maxMessageSize: maxMessageSize),
            VDP.serverPort: MessageAssembler(port: VDP.serverPort, maxMessageSize: maxMessageSize),
        ]
    }

    func reset() {
        header.removeAll(keepingCapacity: true)
        remaining = 0
        assemblers.values.forEach { $0.reset() }
    }

    func feed(_ bytes: UnsafeRawBufferPointer, emit: (AgentMessage) -> Void) throws {
        var p = 0
        while p < bytes.count {
            if remaining == 0 {
                let n = Swift.min(chunkHeaderSize - header.count, bytes.count - p)
                header.append(contentsOf: bytes[p..<(p + n)])
                p += n
                guard header.count == chunkHeaderSize else { break }
                var r = ByteReader(header)
                port = r.u32()!
                let size = r.u32()!
                header.removeAll(keepingCapacity: true)
                guard assemblers[port] != nil else { throw ProtocolError.badPort(port) }
                // The header caps chunks at 2048 bytes; allow slack, but a huge value means the
                // stream is out of step.
                guard size <= 65536 else { throw ProtocolError.badChunkSize(size) }
                remaining = Int(size)
                if remaining == 0 { continue }
            }
            let n = Swift.min(remaining, bytes.count - p)
            try assemblers[port]!.feed(UnsafeRawBufferPointer(rebasing: bytes[p..<(p + n)]), emit: emit)
            p += n
            remaining -= n
        }
    }
}

// MARK: - Logging

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()
private let logLock = NSLock()

func log(_ s: String) {
    logLock.lock()
    defer { logLock.unlock() }
    FileHandle.standardError.write(Data("\(logFormatter.string(from: Date())) \(s)\n".utf8))
}
