// unit.swift: unit tests for the pieces that need no device or client. test_agent.py compiles
// this in the VM as main.swift together with Sources/Protocol.swift and Sources/FileXfer.swift.
//   - FileXfer.sanitize: names a real client cannot send (spice-gtk sends only a basename), such
//     as "../x" or a 300-byte name with a long extension, which once crashed the agent.
//   - FileXfer.parseKeyFile, FileXfer.publish (never overwrites).
//   - Chunk reassembly: one message split across chunks and reads in every possible way.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: @autoclosure () -> String) {
    if !cond { failures += 1; print("FAIL \(msg())") }
}

// sanitize
let cases: [(String, String)] = [
    ("plain.txt", "plain.txt"),
    ("../escape.txt", "escape.txt"),
    ("/etc/passwd", "passwd"),
    ("a/b/../../c.txt", "c.txt"),
    ("..", "dropped-file"),
    ("", "dropped-file"),
    ("...", "dropped-file"),
    (".hidden", "hidden"),
    (" .profile", "profile"),
    (". .x", "x"),
    ("ctrl\u{01}chars\u{7f}\u{85}.txt", "ctrlchars.txt"),
    ("cod\u{202E}fdp.exe", "codfdp.exe"),
    ("we:ird.txt", "weird.txt"),
    ("tab\tname.txt", "tabname.txt"),
]
for (input, want) in cases {
    let got = FileXfer.sanitize(input)
    expect(got == want, "sanitize(\(input.debugDescription)) = \(got.debugDescription), want \(want.debugDescription)")
}
let longExt = "x." + String(repeating: "a", count: 250)        // crashed before the fix
let longBase = String(repeating: "b", count: 300) + ".txt"
let longUnicode = String(repeating: "é", count: 200) + ".png"  // 2 bytes each
let dotLongExt = "." + String(repeating: "c", count: 250)
for n in [longExt, longBase, longUnicode, dotLongExt] {
    let got = FileXfer.sanitize(n)
    expect(got.utf8.count <= 200 && !got.isEmpty && !got.hasPrefix("."),
           "sanitize(\(n.prefix(12))... \(n.utf8.count) B) = \(got.prefix(20))... \(got.utf8.count) B")
}
expect(FileXfer.sanitize(longBase).hasSuffix(".txt"), "long name lost its short extension")
expect(FileXfer.sanitize(longUnicode).hasSuffix(".png"), "long unicode name lost its extension")

// parseKeyFile
let kf = FileXfer.parseKeyFile("[vdagent-file-xfer]\nname=  a\\sb\\\\c\\n.txt\nsize=42\n[other]\nname=no\n")
expect(kf["name"] == "a b\\c\n.txt" && kf["size"] == "42", "parseKeyFile: \(kf)")

// publish: exclusive, numbered
let dir = NSTemporaryDirectory() + "sa-unit-\(getpid())"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func stage(_ s: String) -> String {
    let p = dir + "/stage-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: p, contents: Data(s.utf8))
    return p
}
FileManager.default.createFile(atPath: dir + "/r.txt", contents: Data("existing".utf8))
for (i, want) in ["r (1).txt", "r (2).txt"].enumerated() {
    let r = FileXfer.publish(stage("new \(i)"), directory: dir, name: "r.txt")
    if case .success(let p) = r { expect((p as NSString).lastPathComponent == want, "publish -> \(p)") }
    else { expect(false, "publish failed: \(r)") }
}
expect((try? String(contentsOfFile: dir + "/r.txt", encoding: .utf8)) == "existing", "publish overwrote an existing file")
let noExt = FileXfer.publish(stage("x"), directory: dir, name: "noext")
if case .success(let p) = noExt { expect(p.hasSuffix("/noext"), "publish noext -> \(p)") } else { expect(false, "publish noext failed") }
try? FileManager.default.removeItem(atPath: dir)

// Chunk reassembly: feed every split of a three-chunk message stream.
var payload = Data()
for i in 0..<5000 { payload.append(UInt8(truncatingIfNeeded: i * 7)) }
let stream = encodeMessage(type: 4, data: payload) + encodeMessage(type: 9, data: Data())
var splits = 0
for cut in stride(from: 1, to: stream.count, by: 37) + [1, 7, 8, 9, 27, 28, 29, stream.count - 1] {
    let reader = ChunkReader(maxMessageSize: 1 << 20)
    var got: [AgentMessage] = []
    do {
        for part in [stream[0..<cut], stream[cut...]] {
            try Data(part).withUnsafeBytes { try reader.feed($0) { got.append($0) } }
        }
    } catch { expect(false, "split at \(cut): \(error)") }
    expect(got.count == 2 && got[0].type == 4 && got[0].data == payload && got[1].type == 9 && got[1].data.isEmpty,
           "split at \(cut): got \(got.map { ($0.type, $0.data.count) })")
    splits += 1
}
// Byte by byte.
do {
    let reader = ChunkReader(maxMessageSize: 1 << 20)
    var got: [AgentMessage] = []
    for b in stream { try [b].withUnsafeBytes { try reader.feed($0) { got.append($0) } } }
    expect(got.count == 2 && got[0].data == payload, "byte-by-byte: \(got.count) messages")
} catch { expect(false, "byte-by-byte: \(error)") }
// Each chunk carries at most 2048 data bytes.
var off = 0, chunks = 0
while off < stream.count {
    let size = Int(stream[off + 4]) | Int(stream[off + 5]) << 8 | Int(stream[off + 6]) << 16 | Int(stream[off + 7]) << 24
    expect(size <= 2048, "chunk of \(size) bytes")
    off += 8 + size; chunks += 1
}
expect(off == stream.count && chunks == 4, "chunking: \(chunks) chunks, end \(off)/\(stream.count)")

print(failures == 0 ? "unit: all passed (\(cases.count + 4) names, \(splits) splits)" : "unit: \(failures) failed")
exit(failures == 0 ? 0 : 1)
